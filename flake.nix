{
  description = "TeslaMate Logger";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    devenv.url = "github:cachix/devenv/fed89fff44ccbc73f91d69ca326ac241baeb1726"; # https://github.com/cachix/devenv/issues/1497
    devenv-root.url = "file+file:///dev/null";
    devenv-root.flake = false;
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

  };

  outputs =
    inputs@{ self
    , flake-parts
    , devenv
    , devenv-root
    , ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      flake.nixosModules.default = import ./module.nix { inherit self; };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      # See ./nix/modules/*.nix for the modules that are imported here.
      imports = [
        inputs.devenv.flakeModule
        ./nix/flake-modules/formatter.nix
      ];

      perSystem =
        { config
        , self'
        , inputs'
        , pkgs
        , system
        , ...
        }:
        # legacy
        let
          inherit (pkgs.lib) optional optionals;
          nixpkgs = inputs.nixpkgs;
          pkgs = nixpkgs.legacyPackages.${system};

          elixir = pkgs.beam.packages.erlang_26.elixir_1_16;
          beamPackages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_26;

          src = ./.;
          version = builtins.readFile ./VERSION;
          pname = "teslamate";

          mixFodDeps = beamPackages.fetchMixDeps {
            TOP_SRC = src;
            pname = "${pname}-mix-deps";
            inherit src version;
            hash = "sha256-Y+CGgvnSCiiuyhtsQ+j0vayq1IHO5IEPVl+V/wwTd6w=";
            # hash = pkgs.lib.fakeHash;
          };

          nodejs = pkgs.nodejs;
          nodePackages = pkgs.buildNpmPackage {
            name = "teslamate";
            src = ./assets;
            npmDepsHash = "sha256-05AKPyms4WP8MHBqWMup8VXR3a1tv/f/7jT8c6EpWBw=";
            # npmDepsHash = pkgs.lib.fakeHash;
            dontNpmBuild = true;
            inherit nodejs;

            installPhase = ''
              mkdir $out
              cp -r node_modules $out
              ln -s $out/node_modules/.bin $out/bin

              rm $out/node_modules/phoenix
              ln -s ${mixFodDeps}/phoenix $out/node_modules

              rm $out/node_modules/phoenix_html
              ln -s ${mixFodDeps}/phoenix_html $out/node_modules

              rm $out/node_modules/phoenix_live_view
              ln -s ${mixFodDeps}/phoenix_live_view $out/node_modules
            '';
          };

          cldr = pkgs.fetchFromGitHub {
            owner = "elixir-cldr";
            repo = "cldr";
            rev = "v2.37.5";
            sha256 = "sha256-T5Qvuo+xPwpgBsqHNZYnTCA4loToeBn1LKTMsDcCdYs=";
            # sha256 = pkgs.lib.fakeHash;
          };

          pkg = beamPackages.mixRelease {
            TOP_SRC = src;
            inherit
              pname
              version
              elixir
              src
              mixFodDeps
              ;

            LOCALES = "${cldr}/priv/cldr";

            postBuild = ''
              ln -sf ${mixFodDeps}/deps deps
              ln -sf ${nodePackages}/node_modules assets/node_modules
              export PATH="${pkgs.nodejs}/bin:${nodePackages}/bin:$PATH"
              ${nodejs}/bin/npm run deploy --prefix ./assets

              # for external task you need a workaround for the no deps check flag
              # https://github.com/phoenixframework/phoenix/issues/2690
              mix do deps.loadpaths --no-deps-check, phx.digest
              mix phx.digest --no-deps-check
            '';

            meta = {
              mainProgram = "teslamate";
            };
          };

          postgres_port = 7000;
          mosquitto_port = 7001;
          process_compose_port = 7002;

          psql = pkgs.writeShellScriptBin "teslamate_psql" ''
            exec "${pkgs.postgresql}/bin/psql" --host "$DATABASE_HOST" --user "$DATABASE_USER" --port "$DATABASE_PORT" "$DATABASE_NAME" "$@"
          '';
          mosquitto_sub = pkgs.writeShellScriptBin "teslamate_sub" ''
            exec "${pkgs.mosquitto}/bin/mosquitto_sub" -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" "$@"
          '';

          devShell = inputs.devenv.lib.mkShell {
            inherit inputs pkgs;

            modules = with pkgs; [
              {
                devenv.root =
                  let
                    devenvRootFileContent = builtins.readFile devenv-root.outPath;
                  in
                  pkgs.lib.mkIf (devenvRootFileContent != "") devenvRootFileContent;
                packages =
                  [
                    elixir
                    elixir_ls
                    node2nix
                    nodejs
                    prefetch-npm-deps
                    # for dashboard scripts
                    jq
                    psql
                    mosquitto
                    mosquitto_sub
                    config.treefmt.build.wrapper
                  ]
                  ++ builtins.attrValues config.treefmt.build.programs
                  # ++ optional stdenv.isLinux [
                  #   inotify-tools # disabled to avoid error: A definition for option `packages."[definition 4-entry 16]"' is not of type `package'.
                  #   glibcLocales # disabled to avoid error:  A definition for option `packages."[definition 4-entry 16]"' is not of type `package'.
                  # ]
                  ++ optional stdenv.isDarwin terminal-notifier
                  ++ optionals stdenv.isDarwin (
                    with darwin.apple_sdk.frameworks;
                    [
                      CoreFoundation
                      CoreServices
                    ]
                  );
                enterShell = ''
                  export LOCALES="${cldr}/priv/cldr";
                  export PORT="4000"
                  export ENCRYPTION_KEY="your_secure_encryption_key_here"
                  export DATABASE_USER="teslamate"
                  export DATABASE_PASS="your_secure_password_here"
                  export DATABASE_NAME="teslamate"
                  export DATABASE_HOST="127.0.0.1"
                  export DATABASE_PORT="${toString postgres_port}"
                  export MQTT_HOST="127.0.0.1"
                  export MQTT_PORT="${toString mosquitto_port}"
                  export RELEASE_COOKIE="1234567890123456789"
                  export TZDATA_DIR="$PWD/tzdata"
                  export MIX_REBAR3="${rebar3}/bin/rebar3";
                  mix deps.get
                '';
                enterTest = ''
                  mix test
                '';
                processes.mqtt = {
                  exec = "${pkgs.mosquitto}/bin/mosquitto -p ${toString mosquitto_port}";
                };
                process.managers.process-compose = {
                  port = process_compose_port;
                  tui.enable = true;
                };
                services.postgres = {
                  enable = true;
                  package = pkgs.postgresql_16; # 17 is not yet available in nixpkgs
                  listen_addresses = "127.0.0.1";
                  port = postgres_port;
                  initialDatabases = [{ name = "teslamate"; }];
                  initialScript = ''
                    CREATE USER teslamate with encrypted password 'your_secure_password_here';
                    GRANT ALL PRIVILEGES ON DATABASE teslamate TO teslamate;
                    ALTER USER teslamate WITH SUPERUSER;
                  '';
                };
              }
            ];

          };

          moduleTest =
            (nixpkgs.lib.nixos.runTest {
              hostPkgs = pkgs;
              defaults.documentation.enable = false;
              imports = [
                {
                  name = "teslamate";
                  nodes.server = {
                    imports = [ self'.nixosModules.default ];
                    services.teslamate = {
                      enable = true;
                      secretsFile = builtins.toFile "teslamate.env" ''
                        ENCRYPTION_KEY=123456789
                        DATABASE_PASS=123456789
                        RELEASE_COOKIE=123456789
                      '';
                      postgres.enable_server = true;
                      grafana.enable = true;
                    };
                  };

                  testScript = ''
                    server.wait_for_open_port(4000)
                  '';
                }
              ];
            }).config.result;

          emptyTest = pkgs.stdenv.mkDerivation {
            name = "noTest";
            buildPhase = ''
              echo "Tests are only supported on Linux."
            '';
          };
        in
        {
          packages = {
            devenv-up = devShell.config.procfileScript;
            default = pkg;
          };
          devShells.default = devShell;

          # for `nix flake check`
          checks = {
            default = if pkgs.stdenv.isLinux then moduleTest else emptyTest;
            # formatter check is done in the formatter module
          };
        };
    };
}
