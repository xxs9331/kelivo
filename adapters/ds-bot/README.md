# DS Bot adapter

`0001-kelivo-sync.patch` contains the companion DS Bot plugin changes, preserved
here so the user's Kelivo fork has both sides of the sync implementation.
It does not run inside Flutter or change the production DSH installation.

Apply it to [Fei2411/DeepSeek-Bot](https://github.com/Fei2411/DeepSeek-Bot) at
`7e1c518` (DS Bot 0.1.3). The companion commit is `49c0187` in the local
`/home/lenovo/projects/deepseek-bot-sync` checkout, branch `feature/kelivo-sync`.
The upstream plugin is licensed under Apache-2.0; retain its license when
redistributing a patched plugin package.

```sh
git checkout -b feature/kelivo-sync 7e1c518
git apply --check /path/to/kelivo/adapters/ds-bot/0001-kelivo-sync.patch
git apply /path/to/kelivo/adapters/ds-bot/0001-kelivo-sync.patch
cd ds-bot
npm ci
npm run harness
npm run build
npm test
npm run lint
```

See [testing and scope](../../docs/sync/DSH-TESTING.md) for the pair-and-continue
flow and the keyless cross-client model-request check.
