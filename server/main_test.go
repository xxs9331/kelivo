package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestPullPagesBoundBytesAsWellAsRecords(t *testing.T) {
	s, h := testService(t)
	token := pair(t, s, h, "a")
	payload := json.RawMessage(`{"text":"` + strings.Repeat("x", 900*1024) + `"}`)
	for batch := 0; batch < 4; batch++ {
		var records []record
		for i := 0; i < 10; i++ {
			records = append(records, record{Kind: "message", ID: fmt.Sprintf("m-%d", batch*10+i), Updated: now(), Origin: "a", Payload: payload})
		}
		push(t, h, token, "a", fmt.Sprintf("batch-%d", batch), records...)
	}
	cursor := int64(0)
	count := 0
	for {
		status, body := request(t, h, "GET", fmt.Sprintf("/v1/changes?cursor=%d&limit=500", cursor), token, nil)
		if status != 200 || len(body) > 17*1024*1024 {
			t.Fatalf("oversized/failed pull page: status=%d bytes=%d", status, len(body))
		}
		var page struct {
			Changes []record `json:"changes"`
			Cursor  int64    `json:"nextCursor"`
			More    bool     `json:"hasMore"`
		}
		if err := json.Unmarshal(body, &page); err != nil {
			t.Fatal(err)
		}
		if page.Cursor <= cursor {
			t.Fatal("page did not advance")
		}
		cursor = page.Cursor
		count += len(page.Changes)
		if !page.More {
			break
		}
	}
	if count != 40 || cursor != 40 {
		t.Fatalf("lost records: count=%d cursor=%d", count, cursor)
	}
}

func TestDatabaseAndSidecarsArePrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync.db")
	s, err := openService(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.db.Close() })
	for _, name := range []string{path, path + "-wal", path + "-shm"} {
		info, err := os.Stat(name)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("database file must be private: %s %v", name, err)
		}
		if err := os.Chmod(name, 0644); err != nil {
			t.Fatal(err)
		}
	}
	reopened, err := openService(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.db.Close()
	for _, name := range []string{path, path + "-wal", path + "-shm"} {
		info, err := os.Stat(name)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("existing database file must be private: %s %v", name, err)
		}
	}
}

func testService(t *testing.T) (*service, *httptest.Server) {
	t.Helper()
	s, err := openService(filepath.Join(t.TempDir(), "sync.db"))
	if err != nil {
		t.Fatal(err)
	}
	h := httptest.NewServer(s.routes())
	t.Cleanup(func() { h.Close(); s.db.Close() })
	return s, h
}
func request(t *testing.T, h *httptest.Server, method, path, token string, body any) (int, []byte) {
	t.Helper()
	var b []byte
	if body != nil {
		var err error
		b, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, h.URL+path, bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := h.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, out
}
func pair(t *testing.T, s *service, h *httptest.Server, id string) string {
	t.Helper()
	code, err := s.pairCode()
	if err != nil {
		t.Fatal(err)
	}
	status, b := request(t, h, "POST", "/v1/pair/claim", "", map[string]string{"code": code, "deviceId": id, "deviceName": id, "platform": "test"})
	if status != 200 {
		t.Fatalf("claim: %d %s", status, b)
	}
	var out struct {
		Token string `json:"deviceToken"`
	}
	if json.Unmarshal(b, &out) != nil || out.Token == "" {
		t.Fatal(string(b))
	}
	return out.Token
}
func push(t *testing.T, h *httptest.Server, token, device, change string, r ...record) pushResponse {
	t.Helper()
	status, b := request(t, h, "POST", "/v1/changes", token, pushRequest{change, device, r})
	if status != 200 {
		t.Fatalf("push: %d %s", status, b)
	}
	var out pushResponse
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}
func conversation(id string, time int64, title string) record {
	b, _ := json.Marshal(map[string]string{"title": title})
	return record{Kind: "conversation", ID: id, Updated: time, Payload: b}
}

func TestPairSingleUseExpiryAndRevocation(t *testing.T) {
	s, h := testService(t)
	code, err := s.pairCode()
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]string{"code": code, "deviceId": "a", "deviceName": "Phone", "platform": "android"}
	status, b := request(t, h, "POST", "/v1/pair/claim", "", body)
	if status != 200 {
		t.Fatal(status, string(b))
	}
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	token := out["deviceToken"].(string)
	status, _ = request(t, h, "POST", "/v1/pair/claim", "", body)
	if status != 401 {
		t.Fatal(status)
	}
	code, err = s.pairCode()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.Exec("UPDATE meta SET value='1' WHERE key='pair_expiry'"); err != nil {
		t.Fatal(err)
	}
	body["code"] = code
	status, _ = request(t, h, "POST", "/v1/pair/claim", "", body)
	if status != 401 {
		t.Fatal(status)
	}
	status, _ = request(t, h, "GET", "/v1/state", token, nil)
	if status != 200 {
		t.Fatal(status)
	}
	status, _ = request(t, h, "DELETE", "/v1/devices/a", token, nil)
	if status != 204 {
		t.Fatal(status)
	}
	status, _ = request(t, h, "GET", "/v1/state", token, nil)
	if status != 401 {
		t.Fatal(status)
	}
	var stored string
	if err = s.db.QueryRow("SELECT token_hash FROM devices").Scan(&stored); err != nil || stored == token {
		t.Fatal("plaintext token")
	}
}

func TestIdempotenceLWWAndPermanentDelete(t *testing.T) {
	s, h := testService(t)
	a := pair(t, s, h, "a")
	b := pair(t, s, h, "b")
	r := conversation("c", 100, "A")
	first := push(t, h, a, "a", "one", r)
	retry := push(t, h, a, "a", "one", r)
	if first.Cursor != retry.Cursor || first.Time != retry.Time {
		t.Fatal("receipt not replayed")
	}
	noOp := push(t, h, a, "a", "another", r)
	if noOp.Cursor != first.Cursor {
		t.Fatal("duplicate version created seq")
	}
	loser := push(t, h, a, "a", "older", conversation("c", 99, "old"))
	if len(loser.Superseded) != 1 || loser.Superseded[0].Winner == nil {
		t.Fatal("missing winner")
	}
	winner := push(t, h, b, "b", "tie", conversation("c", 100, "B"))
	if len(winner.Applied) != 1 {
		t.Fatal("device tie-break failed")
	}
	deleted := record{Kind: "conversation", ID: "c", Updated: 101, Deleted: true}
	push(t, h, b, "b", "delete", deleted)
	resurrection := push(t, h, a, "a", "late", conversation("c", 102, "resurrect"))
	if len(resurrection.Superseded) != 1 || !resurrection.Superseded[0].Winner.Deleted {
		t.Fatal("conversation resurrected")
	}
	status, _ := request(t, h, "POST", "/v1/changes", a, pushRequest{"one", "a", []record{conversation("c", 103, "changed")}})
	if status != 409 {
		t.Fatal("changeId reuse accepted", status)
	}
}

func TestCursorPaginationAndConcurrentPush(t *testing.T) {
	s, h := testService(t)
	a := pair(t, s, h, "a")
	b := pair(t, s, h, "b")
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			dev, token := "a", a
			if i%2 == 1 {
				dev, token = "b", b
			}
			push(t, h, token, dev, "concurrent-"+string(rune('A'+i)), conversation("same", int64(100+i), "x"))
		}(i)
	}
	wg.Wait()
	var total int
	var cursor int64
	for {
		status, body := request(t, h, "GET", "/v1/changes?cursor="+strconv64(cursor)+"&limit=1", a, nil)
		if status != 200 {
			t.Fatal(status)
		}
		var p struct {
			Changes []record `json:"changes"`
			Cursor  int64    `json:"nextCursor"`
			More    bool     `json:"hasMore"`
		}
		if json.Unmarshal(body, &p) != nil {
			t.Fatal(string(body))
		}
		if len(p.Changes) > 0 && p.Cursor <= cursor {
			t.Fatal("cursor not monotonic")
		}
		total += len(p.Changes)
		cursor = p.Cursor
		if !p.More {
			break
		}
	}
	if total == 0 {
		t.Fatal("no changes")
	}
	status, _ := request(t, h, "GET", "/v1/changes?cursor=999999", a, nil)
	if status != 409 {
		t.Fatal(status)
	}
	status, snapshot := request(t, h, "GET", "/v1/snapshot", a, nil)
	if status != 200 || len(strings.Split(strings.TrimSpace(string(snapshot)), "\n")) != 2 {
		t.Fatal("snapshot not latest records", string(snapshot))
	}
	var updated int64
	if s.db.QueryRow("SELECT updated_at FROM records").Scan(&updated) != nil || updated != 119 {
		t.Fatal("concurrent LWW failed", updated)
	}
}
func strconv64(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestUnseenConcurrentChangeIsNotSkippedByPushAck(t *testing.T) {
	s, h := testService(t)
	a := pair(t, s, h, "a")
	b := pair(t, s, h, "b")
	push(t, h, b, "b", "b1", conversation("from-b", 100, "B"))
	ack := push(t, h, a, "a", "a1", conversation("from-a", 100, "A"))
	if ack.Cursor != 2 {
		t.Fatal(ack)
	}
	status, body := request(t, h, "GET", "/v1/changes?cursor=0", a, nil)
	if status != 200 || !bytes.Contains(body, []byte("from-b")) {
		t.Fatal("missed concurrent change")
	}
}

func TestPayloadLimitAuthAndPersistence(t *testing.T) {
	s, h := testService(t)
	a := pair(t, s, h, "a")
	status, _ := request(t, h, "POST", "/v1/changes", a, pushRequest{"x", "other", []record{conversation("c", 100, "x")}})
	if status != 400 {
		t.Fatal(status)
	}
	status, _ = request(t, h, "POST", "/v1/changes", a, pushRequest{"large", "a", []record{conversation("c", 100, strings.Repeat("x", 1<<20))}})
	if status != 413 {
		t.Fatal(status)
	}
	status, _ = request(t, h, "GET", "/v1/changes?cursor=0&limit=-1", a, nil)
	if status != 400 {
		t.Fatal(status)
	}
	push(t, h, a, "a", "saved", conversation("c", 100, "saved"))
	var path string
	if err := s.db.QueryRow("SELECT file FROM pragma_database_list WHERE name='main'").Scan(&path); err != nil {
		t.Fatal(err)
	}
	s.db.Close()
	reopened, err := openService(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.db.Close()
	var count int
	if reopened.db.QueryRow("SELECT COUNT(*) FROM records").Scan(&count) != nil || count != 1 {
		t.Fatal("data lost")
	}
}
