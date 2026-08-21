# Verification

- Deployment `92b508da-269c-401f-9efd-4e03b7b9dafa`: `SUCCESS`
- Image digest: `sha256:d838d7e09e629956c0ba2922aad5a86af7b71da969d4b226ef7da3cce9af5991`
- Unit/integration tests: 48/48 passed
- Typecheck/build: passed
- npm audit: 0 vulnerabilities
- Public health: `GET /healthz` → `200 ok`
- Public message chain: `RAILWAY_E2E_OK` delivered from `railway-beta` to `railway-alpha`
- Authorization: wrong bearer token rejected with 401
- Volume: channel `quick-weasel-b2ae` accepted its original token after Railway restart
