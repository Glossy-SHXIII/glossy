{
  description = "Debug Linux hosts over SSH with a local LLM: MCP server, dashboard, host tooling";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        # Installed by install.sh on other distros; here it is a real package.
        linux-mcp-server = pkgs.python3Packages.buildPythonApplication rec {
          pname = "linux-mcp-server";
          version = "1.6.0";
          format = "wheel";

          src = pkgs.python3Packages.fetchPypi {
            inherit version format;
            pname = "linux_mcp_server";
            dist = "py3";
            python = "py3";
            hash = "sha256-lo1Dc8Knz39jg6yHS8racaTZfrV+E2qme9Wm5qZMyHY=";
          };

          # nixpkgs ships fastmcp 3.2.3 (wheel wants >= 3.2.4) and fakeredis 2.36
          # (wheel pins < 2.35 for a docket/redis path this server never uses).
          pythonRelaxDeps = [ "fastmcp" "fakeredis" ];

          dependencies = with pkgs.python3Packages; [
            asyncssh
            bcrypt
            fakeredis
            fastmcp
            httpx
            pydantic
            pydantic-settings
          ];

          pythonImportsCheck = [ "linux_mcp_server" ];

          meta = {
            description = "MCP server for read-only Linux system administration and diagnostics";
            homepage = "https://github.com/rhel-lightspeed/linux-mcp-server";
            mainProgram = "linux-mcp-server";
          };
        };

        # The dashboard, with the MCP server and SSH on its PATH.
        dashboard = pkgs.writeShellApplication {
          name = "glossy-dashboard";
          runtimeInputs = [ pkgs.python3 linux-mcp-server pkgs.openssh ];
          text = ''
            cd ${./server}
            exec python3 server.py "$@"
          '';
        };

        default = dashboard;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.dashboard}/bin/glossy-dashboard";
        };
      });

      # Everything install.sh would install on another distro.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            self.packages.${pkgs.stdenv.hostPlatform.system}.linux-mcp-server
            pkgs.python3
            pkgs.openssh
            pkgs.curl
            pkgs.google-cloud-sdk # for ./add-host.sh --gcloud and the gce-snapshot recipe
            # capture/ tooling: local clones, image handling, process checkpoints
            pkgs.qemu
            pkgs.OVMFFull # UEFI firmware; GCE disks are UEFI so local clones need it
            pkgs.libguestfs-with-appliance # virt-rescue, for the bare-metal path
            pkgs.criu
            pkgs.zstd
          ];
          shellHook = ''
            echo "glossy dev shell: linux-mcp-server $(linux-mcp-server --version 2>/dev/null || echo '?')"
            echo "  ./add-host.sh <name> <user@host>     add a host"
            echo "  python3 server/server.py             dashboard on http://127.0.0.1:8000"
            echo "  capture/inspect.sh <host>            read-only; recommends a capture recipe"
          '';
        };
      });
    };
}
