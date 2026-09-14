# Connect Hermes to Cuate

In macOS Cuate, open **Settings → Hermes Agent → Connect Hermes**. The compact
guide offers two routes and opens or copies the complete instructions in the
app's language (English, Spanish or Russian). Opening it does not execute any
commands or include saved credentials.

## Choose a route

| | With a domain | Without a domain |
|---|---|---|
| Connection | HTTPS to the VPS | SSH tunnel from the Mac to the VPS |
| Devices | Mac and Android use the same addresses | Only the Mac where the tunnel is installed |
| What is needed | Domain DNS, server SSH access, inbound TCP 80/443 | Working SSH key login from the Mac |
| After setup | Server services and Caddy start at boot | Server services start at boot; the tunnel starts at Mac login and reconnects |
| Terminal kept open | No | No |

The complete command blocks target a dedicated Ubuntu 22/24 VPS, a root login
and a standard Hermes installation at `/root/.hermes/hermes-agent`. Docker,
custom service users and existing web stacks require administrator setup; see
the [advanced HTTPS guide](hermes-vps-setup.md). The HTTPS block refuses to
replace an existing Caddy configuration or a server already listening on
80/443. DNS and firewall configuration remain explicit user steps.

## Four steps

1. **On the VPS:** install/configure Hermes, choose a provider and model, and
   get a reply in the terminal chat. Provider credentials stay on the VPS.
2. **On the VPS:** run the full server block. It preserves existing keys,
   configures the gateway and Dashboard, applies the bundled compatibility
   patch, enables the two services, and checks authenticated JSON responses.
   Existing service definitions are retained. Save the two printed access keys.
3. **Connect:** configure HTTPS for the domain, or run the Mac tunnel block.
   The tunnel forwards both chat and Dashboard, stores the SSH passphrase in
   macOS Keychain, and installs a login service. Fill in the fields below.
4. **In Cuate:** test the connection, a chat reply, an uploaded text file and a
   downloaded file. Verify a VPS restart and, for SSH, a new Mac login.

## Cuate fields

| Field | Domain | SSH tunnel |
|---|---|---|
| Gateway address | `https://agent.example.com` | `http://127.0.0.1:18642` |
| API key | `API_SERVER_KEY` | `API_SERVER_KEY` |
| Dashboard URL | `https://dash.example.com` | `http://127.0.0.1:19119` |
| Dashboard token | `HERMES_DASHBOARD_SESSION_TOKEN` | `HERMES_DASHBOARD_SESSION_TOKEN` |
| VPS through SSH tunnel | Off | **On** |

Save each key with its own Save button. The keys for gateway and Dashboard are
different from the model provider's key. With an SSH tunnel, the explicit
toggle tells Cuate that files must travel to another computer even though the
connection address is loopback. It also hides local-install repair offers.
The toggle alone does not install or start a tunnel. It defaults to off so
existing local Hermes installations keep their behavior.

A successful gateway check does not prove file transfer. Docker terminal
backends must mount the upload folder at the same path inside the container.
The Mac must be awake and online for its tunnel to be available.

## Maintenance

The instructions do not schedule Hermes updates. A reboot preserves the patch;
an update may overwrite it. After an intentional `hermes update`, repeat the
compatibility step and check chat and files. Hosting-provider jobs may have
their own update policy.

The full in-app guide includes a separate Python/SQLite troubleshooting block
for uv-managed Python 3.11. It updates uv before downloading Python and prints
the SQLite version actually used by Hermes. It does not manipulate the chat
database. Unsupported patch layouts are refused rather than guessed.

The guide's source is `HermesConnectionGuide.swift`; localized prose is in
`HermesLocalization.swift`. Its server block reuses the existing patch in
`HermesSettingsView.swift`, without another copy of the transform.
