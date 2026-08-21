# Verification

## Automated

- `npm test`: 7 files, 51 tests passed
- `npm run typecheck`: passed
- `npm run build`: passed

## Railway

- Deployment: `44543fc3-2c07-4edd-baf8-586512317afe`
- `POST /mcp` advertises `resources` and `open_channel_view`
- `resources/read` returns `ui://rogerthat/channel-view-v1.html`
- MIME: `text/html;profile=mcp-app`
- CSP only permits `https://rogerthat-production-fff6.up.railway.app`

## Pending

- ChatGPT Developer Mode requires user confirmation before installing the unverified connector.
- After installation, verify View rendering and one peer message -> `ui/message` round trip.
