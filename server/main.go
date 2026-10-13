package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

type record struct {
	Seq     int64           `json:"serverSeq,omitempty"`
	Kind    string          `json:"kind"`
	ID      string          `json:"id"`
	Updated int64           `json:"updatedAt"`
	Deleted bool            `json:"deleted"`
	Origin  string          `json:"originDevice"`
	Payload json.RawMessage `json:"payload"`
}

type receipt struct {
	Kind   string  `json:"kind"`
	ID     string  `json:"id"`
	Seq    int64   `json:"serverSeq"`
	Status string  `json:"status"`
	Winner *record `json:"winner,omitempty"`
}

type pushRequest struct {
	ChangeID string   `json:"changeId"`
	DeviceID string   `json:"deviceId"`
	Records  []record `json:"records"`
}

type pushResponse struct {
	Applied    []receipt `json:"applied"`
	Superseded []receipt `json:"superseded"`
	Cursor     int64     `json:"nextCursor"`
	Time       int64     `json:"serverTimeUs"`
}

type service struct{ db *sql.DB }

const schema = `
CREATE TABLE IF NOT EXISTS devices (
 device_id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL,
 token_hash TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, revoked_at INTEGER
);
CREATE TABLE IF NOT EXISTS records (
 kind TEXT NOT NULL, id TEXT NOT NULL, updated_at INTEGER NOT NULL,
 deleted INTEGER NOT NULL, origin_device TEXT NOT NULL, payload TEXT,
 server_seq INTEGER NOT NULL, PRIMARY KEY(kind,id)
);
CREATE TABLE IF NOT EXISTS changes (
 server_seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
 id TEXT NOT NULL, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL,
 origin_device TEXT NOT NULL, payload TEXT
);
CREATE TABLE IF NOT EXISTS push_receipts (
 device_id TEXT NOT NULL, change_id TEXT NOT NULL, request_hash TEXT NOT NULL,
 response TEXT NOT NULL, PRIMARY KEY(device_id,change_id)
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS rate_buckets (
 identity TEXT PRIMARY KEY, minute INTEGER NOT NULL, count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_records_seq ON records(server_seq);
PRAGMA user_version=1;
`

func openService(path string) (*service, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return nil, err
	}
	if err := file.Close(); err != nil {
		return nil, err
	}
	// SQLite derives new WAL permissions from the database's current mode.
	for _, name := range []string{path, path + "-wal", path + "-shm"} {
		if err := os.Chmod(name, 0600); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	fail := func(err error) (*service, error) { db.Close(); return nil, err }
	var version int
	if err = db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return fail(err)
	}
	if version > 1 {
		return fail(fmt.Errorf("unsupported database version %d", version))
	}
	if _, err = db.Exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;"); err != nil {
		return fail(err)
	}
	if _, err = db.Exec(schema); err != nil {
		return fail(err)
	}
	if _, err = db.Exec("INSERT OR IGNORE INTO meta VALUES ('server_id',?)", secret()); err != nil {
		return fail(err)
	}
	return &service{db}, nil
}

func secret() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func hash(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
func now() int64           { return time.Now().UTC().UnixMicro() }

func (s *service) pairCode() (string, error) {
	code := secret()[:16]
	_, err := s.db.Exec("INSERT OR REPLACE INTO meta VALUES ('pair_hash',?),('pair_expiry',?)", hash(code), strconv.FormatInt(now()+int64(5*time.Minute/time.Microsecond), 10))
	return code, err
}

func jsonResponse(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func apiError(w http.ResponseWriter, status int, code string) {
	jsonResponse(w, status, map[string]any{"error": map[string]string{"code": code, "message": code}})
}
func decode(w http.ResponseWriter, r *http.Request, v any, max int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			apiError(w, 413, "payload_too_large")
		} else {
			apiError(w, 400, "invalid_request")
		}
		return false
	}
	if d.Decode(&struct{}{}) != io.EOF {
		apiError(w, 400, "invalid_request")
		return false
	}
	return true
}
func validID(id string) bool { return len(id) > 0 && len(id) <= 200 && strings.TrimSpace(id) == id }

func (s *service) routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		if s.db.PingContext(r.Context()) != nil {
			apiError(w, 503, "server_error")
			return
		}
		jsonResponse(w, 200, map[string]string{"status": "ok"})
	})
	m.HandleFunc("POST /v1/pair/claim", s.claim)
	m.HandleFunc("POST /v1/pair/code", s.authorize(func(w http.ResponseWriter, r *http.Request, _ string) {
		code, err := s.pairCode()
		if err != nil {
			apiError(w, 500, "server_error")
			return
		}
		jsonResponse(w, 200, map[string]any{"code": code, "expiresIn": 300})
	}))
	m.HandleFunc("POST /v1/changes", s.authorize(s.push))
	m.HandleFunc("GET /v1/changes", s.authorize(s.pull))
	m.HandleFunc("GET /v1/snapshot", s.authorize(s.snapshot))
	m.HandleFunc("GET /v1/state", s.authorize(s.state))
	m.HandleFunc("GET /v1/devices", s.authorize(s.devices))
	m.HandleFunc("DELETE /v1/devices/{deviceId}", s.authorize(s.revoke))
	return m
}

func (s *service) limited(w http.ResponseWriter, r *http.Request, key string, limit int) bool {
	minute := time.Now().Unix() / 60
	var count int
	err := s.db.QueryRowContext(r.Context(), `INSERT INTO rate_buckets VALUES (?,?,1)
 ON CONFLICT(identity) DO UPDATE SET minute=excluded.minute,
 count=CASE WHEN rate_buckets.minute=excluded.minute THEN rate_buckets.count+1 ELSE 1 END
 RETURNING count`, key, minute).Scan(&count)
	if err != nil {
		apiError(w, 500, "server_error")
		return true
	}
	// Bound the number of unauthenticated IP buckets without a background worker.
	if _, err = s.db.ExecContext(r.Context(), "DELETE FROM rate_buckets WHERE minute < ?", minute-1); err != nil {
		apiError(w, 500, "server_error")
		return true
	}
	if count > limit {
		w.Header().Set("Retry-After", "60")
		apiError(w, 429, "rate_limited")
		return true
	}
	return false
}

func (s *service) authorize(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			apiError(w, 401, "invalid_token")
			return
		}
		var id string
		err := s.db.QueryRowContext(r.Context(), "SELECT device_id FROM devices WHERE token_hash=? AND revoked_at IS NULL", hash(strings.TrimPrefix(h, "Bearer "))).Scan(&id)
		if err == sql.ErrNoRows {
			apiError(w, 401, "invalid_token")
			return
		}
		if err != nil {
			apiError(w, 500, "server_error")
			return
		}
		if supplied := r.Header.Get("X-Device-Id"); supplied != "" && supplied != id {
			apiError(w, 401, "invalid_token")
			return
		}
		if s.limited(w, r, "device:"+id, 600) {
			return
		}
		next(w, r, id)
	}
}

func (s *service) claim(w http.ResponseWriter, r *http.Request) {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	if s.limited(w, r, "pair:"+ip, 10) {
		return
	}
	var req struct {
		Code     string `json:"code"`
		ID       string `json:"deviceId"`
		Name     string `json:"deviceName"`
		Platform string `json:"platform"`
	}
	if !decode(w, r, &req, 4096) {
		return
	}
	if !validID(req.ID) || len(req.Name) > 200 || len(req.Platform) > 50 {
		apiError(w, 400, "invalid_request")
		return
	}
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer tx.Rollback()
	var code string
	var expiry int64
	var serverID string
	err = tx.QueryRow("SELECT value FROM meta WHERE key='pair_hash'").Scan(&code)
	if err != nil && err != sql.ErrNoRows {
		apiError(w, 500, "server_error")
		return
	}
	_ = tx.QueryRow("SELECT value FROM meta WHERE key='pair_expiry'").Scan(&expiry)
	if code != hash(strings.TrimSpace(req.Code)) || expiry < now() {
		apiError(w, 401, "invalid_pair_code")
		return
	}
	token := secret()
	_, err = tx.Exec("INSERT INTO devices VALUES (?,?,?,?,?,NULL) ON CONFLICT(device_id) DO UPDATE SET name=excluded.name,platform=excluded.platform,token_hash=excluded.token_hash,revoked_at=NULL", req.ID, req.Name, req.Platform, hash(token), now())
	if err == nil {
		_, err = tx.Exec("DELETE FROM meta WHERE key IN ('pair_hash','pair_expiry')")
	}
	if err == nil {
		err = tx.QueryRow("SELECT value FROM meta WHERE key='server_id'").Scan(&serverID)
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	jsonResponse(w, 200, map[string]any{"deviceToken": token, "serverId": serverID, "serverTimeUs": now()})
}

func scanRecord(row interface{ Scan(...any) error }) (record, error) {
	var r record
	var payload sql.NullString
	err := row.Scan(&r.Seq, &r.Kind, &r.ID, &r.Updated, &r.Deleted, &r.Origin, &payload)
	if payload.Valid {
		r.Payload = json.RawMessage(payload.String)
	}
	return r, err
}

const columns = "server_seq,kind,id,updated_at,deleted,origin_device,payload"

func wins(a, b record) bool {
	return a.Updated > b.Updated || (a.Updated == b.Updated && a.Origin > b.Origin)
}

func (s *service) push(w http.ResponseWriter, r *http.Request, device string) {
	var req pushRequest
	if !decode(w, r, &req, 16<<20) {
		return
	}
	if !validID(req.ChangeID) || req.DeviceID != device || len(req.Records) == 0 {
		apiError(w, 400, "invalid_request")
		return
	}
	if len(req.Records) > 500 {
		apiError(w, 413, "payload_too_large")
		return
	}
	keys := map[string]bool{}
	for i := range req.Records {
		x := &req.Records[i]
		if (x.Kind != "conversation" && x.Kind != "message") || !validID(x.ID) || x.Updated <= 0 || x.Updated > now()+int64(5*time.Minute/time.Microsecond) || x.Seq != 0 || (x.Origin != "" && x.Origin != device) || keys[x.Kind+"\x00"+x.ID] {
			apiError(w, 400, "invalid_record")
			return
		}
		keys[x.Kind+"\x00"+x.ID] = true
		if len(x.Payload) > 1<<20 {
			apiError(w, 413, "payload_too_large")
			return
		}
		if x.Deleted {
			x.Payload = nil
		} else {
			var obj map[string]any
			if json.Unmarshal(x.Payload, &obj) != nil || obj == nil {
				apiError(w, 400, "invalid_record")
				return
			}
		}
		x.Origin = device
	}
	b, _ := json.Marshal(req)
	requestHash := hash(string(b))
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer tx.Rollback()
	var oldHash, oldResponse string
	err = tx.QueryRow("SELECT request_hash,response FROM push_receipts WHERE device_id=? AND change_id=?", device, req.ChangeID).Scan(&oldHash, &oldResponse)
	if err == nil {
		if oldHash != requestHash {
			apiError(w, 409, "change_id_reused")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = io.WriteString(w, oldResponse)
		return
	}
	if err != sql.ErrNoRows {
		apiError(w, 500, "server_error")
		return
	}
	out := pushResponse{Applied: []receipt{}, Superseded: []receipt{}, Time: now()}
	for _, incoming := range req.Records {
		old, e := scanRecord(tx.QueryRow("SELECT "+columns+" FROM records WHERE kind=? AND id=?", incoming.Kind, incoming.ID))
		if e != nil && e != sql.ErrNoRows {
			apiError(w, 500, "server_error")
			return
		}
		accepted := e == sql.ErrNoRows || wins(incoming, old)
		// Once a conversation is deleted, late title edits must not resurrect it.
		if old.Deleted && incoming.Kind == "conversation" && !incoming.Deleted {
			accepted = false
		}
		if e == nil && incoming.Updated == old.Updated && incoming.Origin == old.Origin && incoming.Deleted == old.Deleted && string(incoming.Payload) == string(old.Payload) {
			out.Applied = append(out.Applied, receipt{incoming.Kind, incoming.ID, old.Seq, "applied", nil})
			continue
		}
		if !accepted {
			out.Superseded = append(out.Superseded, receipt{incoming.Kind, incoming.ID, old.Seq, "superseded", &old})
			continue
		}
		var payload any
		if !incoming.Deleted {
			payload = string(incoming.Payload)
		}
		result, e := tx.Exec("INSERT INTO changes(kind,id,updated_at,deleted,origin_device,payload) VALUES (?,?,?,?,?,?)", incoming.Kind, incoming.ID, incoming.Updated, incoming.Deleted, incoming.Origin, payload)
		if e != nil {
			apiError(w, 500, "server_error")
			return
		}
		incoming.Seq, e = result.LastInsertId()
		if e == nil {
			_, e = tx.Exec("INSERT INTO records(kind,id,updated_at,deleted,origin_device,payload,server_seq) VALUES (?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET updated_at=excluded.updated_at,deleted=excluded.deleted,origin_device=excluded.origin_device,payload=excluded.payload,server_seq=excluded.server_seq", incoming.Kind, incoming.ID, incoming.Updated, incoming.Deleted, incoming.Origin, payload, incoming.Seq)
		}
		if e != nil {
			apiError(w, 500, "server_error")
			return
		}
		out.Applied = append(out.Applied, receipt{incoming.Kind, incoming.ID, incoming.Seq, "applied", nil})
	}
	if err = tx.QueryRow("SELECT COALESCE(MAX(server_seq),0) FROM changes").Scan(&out.Cursor); err != nil {
		apiError(w, 500, "server_error")
		return
	}
	body, err := json.Marshal(out)
	if err == nil {
		_, err = tx.Exec("INSERT INTO push_receipts VALUES (?,?,?,?)", device, req.ChangeID, requestHash, string(body))
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
}

func (s *service) pull(w http.ResponseWriter, r *http.Request, _ string) {
	q := r.URL.Query()
	cursor, err := strconv.ParseInt(q.Get("cursor"), 10, 64)
	if err != nil || cursor < 0 {
		apiError(w, 400, "invalid_cursor")
		return
	}
	limit := 500
	if q.Has("limit") {
		limit, err = strconv.Atoi(q.Get("limit"))
		if err != nil || limit < 1 || limit > 2000 {
			apiError(w, 400, "invalid_limit")
			return
		}
	}
	tx, err := s.db.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer tx.Rollback()
	var high int64
	if err = tx.QueryRow("SELECT COALESCE(MAX(server_seq),0) FROM changes").Scan(&high); err != nil {
		apiError(w, 500, "server_error")
		return
	}
	if cursor > high {
		apiError(w, 409, "cursor_ahead")
		return
	}
	rows, err := tx.Query("SELECT "+columns+" FROM changes WHERE server_seq>? ORDER BY server_seq LIMIT ?", cursor, limit)
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer rows.Close()
	changes := []record{}
	bytes := 0
	for rows.Next() {
		x, e := scanRecord(rows)
		if e != nil {
			apiError(w, 500, "server_error")
			return
		}
		encoded, e := json.Marshal(x)
		if e != nil {
			apiError(w, 500, "server_error")
			return
		}
		// A record-count limit alone can produce hundreds of MiB per page.
		if len(changes) > 0 && bytes+len(encoded) > 16*1024*1024 {
			break
		}
		bytes += len(encoded)
		changes = append(changes, x)
		cursor = x.Seq
	}
	if rows.Err() != nil {
		apiError(w, 500, "server_error")
		return
	}
	jsonResponse(w, 200, map[string]any{"changes": changes, "nextCursor": cursor, "hasMore": cursor < high, "serverTimeUs": now()})
}

func (s *service) snapshot(w http.ResponseWriter, r *http.Request, _ string) {
	tx, err := s.db.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer tx.Rollback()
	var cursor int64
	if tx.QueryRow("SELECT COALESCE(MAX(server_seq),0) FROM changes").Scan(&cursor) != nil {
		apiError(w, 500, "server_error")
		return
	}
	rows, err := tx.Query("SELECT " + columns + " FROM records ORDER BY CASE kind WHEN 'conversation' THEN 0 ELSE 1 END,server_seq")
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer rows.Close()
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	e := json.NewEncoder(w)
	if e.Encode(map[string]any{"kind": "_meta", "cursor": cursor}) != nil {
		return
	}
	for rows.Next() {
		x, err := scanRecord(rows)
		if err != nil || e.Encode(x) != nil {
			return
		}
	}
	if rows.Err() != nil {
		log.Print("snapshot read failed")
	}
}

func (s *service) state(w http.ResponseWriter, r *http.Request, _ string) {
	var cursor int64
	var count int
	if s.db.QueryRowContext(r.Context(), "SELECT COALESCE(MAX(server_seq),0) FROM changes").Scan(&cursor) != nil || s.db.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM devices WHERE revoked_at IS NULL").Scan(&count) != nil {
		apiError(w, 500, "server_error")
		return
	}
	jsonResponse(w, 200, map[string]any{"cursor": cursor, "deviceCount": count, "serverTimeUs": now(), "protocolVersion": 1})
}
func (s *service) devices(w http.ResponseWriter, r *http.Request, _ string) {
	rows, err := s.db.QueryContext(r.Context(), "SELECT device_id,name,platform,created_at FROM devices WHERE revoked_at IS NULL ORDER BY created_at")
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name, platform string
		var created int64
		if rows.Scan(&id, &name, &platform, &created) != nil {
			apiError(w, 500, "server_error")
			return
		}
		out = append(out, map[string]any{"deviceId": id, "deviceName": name, "platform": platform, "createdAt": created})
	}
	if rows.Err() != nil {
		apiError(w, 500, "server_error")
		return
	}
	jsonResponse(w, 200, map[string]any{"devices": out})
}
func (s *service) revoke(w http.ResponseWriter, r *http.Request, _ string) {
	_, err := s.db.ExecContext(r.Context(), "UPDATE devices SET revoked_at=? WHERE device_id=?", now(), r.PathValue("deviceId"))
	if err != nil {
		apiError(w, 500, "server_error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8787", "listen address")
	dbPath := flag.String("db", "data/sync.db", "SQLite database")
	flag.Parse()
	if flag.NArg() == 1 && flag.Arg(0) == "health" {
		c := http.Client{Timeout: 3 * time.Second}
		res, err := c.Get("http://" + *addr + "/health")
		if err != nil {
			log.Fatal(err)
		}
		defer res.Body.Close()
		if res.StatusCode != 200 {
			os.Exit(1)
		}
		return
	}
	s, err := openService(*dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer s.db.Close()
	if flag.NArg() == 1 && flag.Arg(0) == "pair-code" {
		code, err := s.pairCode()
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println(code)
		return
	}
	if flag.NArg() != 0 {
		log.Fatal("unknown command")
	}
	server := http.Server{Addr: *addr, Handler: s.routes(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()
	log.Printf("kelivo-sync listening on %s", *addr)
	if err = server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
