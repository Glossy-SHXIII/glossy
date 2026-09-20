# glossy

Self-hosted LLM plus a fleet of Linux machines it can inspect, without exposing the MCP server
anywhere.

```
 ┌──────────────┐   OpenAI API over TCP (API key)   ┌─────────────────────┐
 │ control node │ ────────────────────────────────> │ llama.cpp on a GPU  │  llm/
 │              │                                   │ (Brev, or your own) │
 │ agent        │                                   └─────────────────────┘
 │   │ stdio                                                    
 │   ▼                                                          
 │ linux-mcp-server │ ──── SSH ───> web1, db1, ...   (managed hosts)
 └──────────────┘
```

* `llm/` builds a Docker Compose file that serves any GGUF model with tool calling, and uploads to
  brev.nvidia.com. See [llm/setup.sh](llm/setup.sh).
* `server/` is a small dashboard: LLM servers with their models and checks, plus every managed host
  with live system facts and a runner for any read-only MCP tool.
* `install.sh` / `add-host.sh` set up the control node and register managed Linux hosts.
* `agent/` investigates a problem you paste into a log: reads the machine, and where it must change
  something, does it on a clone. Not a chat - see [agent/README.md](agent/README.md).
* `capture/` takes a non-disruptive snapshot of a running host and boots it as an isolated,
  disposable clone you can actually run commands in - the part the read-only MCP cannot do.
  See [capture/SAFETY.md](capture/SAFETY.md).

## Two tiers of access

`linux-mcp-server` reaches every managed host and is **read only**: it can look at production and
nothing more. `server/clone_mcp.py` can run commands, write files and restart services, but only on
**debug clones** built by `capture/` - it refuses anything that has ever been a capture source, even
if the inventory claims otherwise. So the machine you can change is always a disposable copy.

## Why the MCP server is never exposed

`linux-mcp-server` runs on the control node over **stdio**, started on demand by the agent as a child
process. It listens on no port, so there is nothing to firewall or authenticate. It reaches managed
machines over **SSH**, which they already run, and every tool is read-only.

Managed machines need no installation: no agent, no container, no new port.

## Setting up the control node

```bash
./install.sh            # or --dry-run to see what it would do
```

Installs uv and `linux-mcp-server`, creates the SSH key, and writes the config files. It detects the
distro (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine, NixOS) and installs only what is missing.
uv brings its own Python, so the distro's Python version does not matter.

Managed hosts get nothing installed: SSH access is the whole requirement.

## Adding a machine

Same network:

```bash
./add-host.sh web1 admin@10.0.0.64
```

Different network, through a bastion the control node can already reach:

```bash
./add-host.sh db1 postgres@10.1.0.5 --jump admin@bastion.example.com
```

Each call writes an entry to `~/.ssh/config`, installs the key, verifies passwordless login, and
records the host in `hosts.toml`. After that the name is what you pass to the tools:
`get_service_status(service_name="nginx", host="web1")`.

### Google Compute Engine

```bash
./add-host.sh api1 --gcloud my-instance --zone us-central1-a          # picks IAP automatically
./add-host.sh api1 --gcloud my-instance --zone us-central1-a --iap    # force IAP
```

Uses `gcloud` for the parts GCE owns: it reads the instance's external IP, authorizes your key
(OS Login or instance metadata) and picks the username. A VM with **no external IP** is reached with
`ProxyCommand gcloud compute start-iap-tunnel`, which needs `roles/iap.tunnelResourceAccessor` and a
firewall rule allowing `35.235.240.0/20` on port 22. Ordinary `ssh api1` works afterwards, so the MCP
server needs to know nothing about GCE.

For machines with no public address and no bastion, put them on a mesh VPN (WireGuard or Tailscale)
and add them by their VPN address. The control node dials out, so the machine still needs no inbound
port beyond SSH.

## Connecting an agent

Any MCP client can start the server over stdio:

```json
{ "command": "linux-mcp-server", "args": [], "env": {} }
```

Point the same agent at the llama.cpp server from `llm/` as its OpenAI-compatible model endpoint.

The dashboard in `server/` starts the same server itself, so `cd server && python3 server.py` is all
that is needed to browse hosts.
