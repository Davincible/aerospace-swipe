{
  description = "Trackpad swipe gestures for AeroSpace workspace switching";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        aerospace-swipe = pkgs.stdenv.mkDerivation {
          pname = "aerospace-swipe";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [ ];
          buildInputs = [ ];

          buildPhase = ''
            runHook preBuild

            ARCH=$(uname -m)
            CFLAGS="-std=c99 -O3 -flto -fomit-frame-pointer -funroll-loops -Wall -Wextra"

            if [ "$ARCH" = "arm64" ]; then
              CFLAGS="$CFLAGS -mcpu=apple-m1"
            fi

            LDFLAGS="-framework CoreFoundation -framework IOKit -framework ApplicationServices -framework Cocoa"
            LDFLAGS="$LDFLAGS -F/System/Library/PrivateFrameworks -framework MultitouchSupport"

            clang $CFLAGS \
              -Isrc \
              src/aerospace.c \
              src/yyjson.c \
              src/haptic.c \
              src/event_tap.m \
              src/main.m \
              $LDFLAGS \
              -o AerospaceSwipe

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/Applications/AerospaceSwipe.app/Contents/MacOS
            mkdir -p $out/bin

            cp AerospaceSwipe $out/Applications/AerospaceSwipe.app/Contents/MacOS/
            ln -s $out/Applications/AerospaceSwipe.app/Contents/MacOS/AerospaceSwipe $out/bin/aerospace-swipe

            cat > $out/Applications/AerospaceSwipe.app/Contents/Info.plist << EOF
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>CFBundleExecutable</key>
              <string>AerospaceSwipe</string>
              <key>CFBundleIdentifier</key>
              <string>com.acsandmann.swipe</string>
              <key>CFBundleName</key>
              <string>AerospaceSwipe</string>
              <key>CFBundleVersion</key>
              <string>1.0.0</string>
              <key>LSBackgroundOnly</key>
              <true/>
              <key>LSUIElement</key>
              <true/>
            </dict>
            </plist>
            EOF

            /usr/bin/codesign --force --sign - \
              $out/Applications/AerospaceSwipe.app/Contents/MacOS/AerospaceSwipe || true

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Trackpad swipe gestures for AeroSpace workspace switching";
            homepage = "https://github.com/Davincible/aerospace-swipe";
            license = licenses.mit;
            platforms = platforms.darwin;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          default = aerospace-swipe;
          aerospace-swipe = aerospace-swipe;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = aerospace-swipe;
          exePath = "/bin/aerospace-swipe";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            clang
          ];
        };
      }
    ) // {
      # Overlay for easy integration into other flakes
      overlays.default = final: prev: {
        aerospace-swipe = self.packages.${prev.system}.aerospace-swipe;
      };

      # NixOS/nix-darwin module
      darwinModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.aerospace-swipe;
        in
        {
          options.services.aerospace-swipe = {
            enable = lib.mkEnableOption "AeroSpace Swipe trackpad gesture support";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.aerospace-swipe;
              description = "The aerospace-swipe package to use";
            };

            haptic = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable haptic feedback on swipe";
            };

            naturalSwipe = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Use natural (inverted) swipe direction";
            };

            wrapAround = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Wrap around between first and last workspace";
            };

            skipEmpty = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Skip empty workspaces when swiping";
            };

            fingers = lib.mkOption {
              type = lib.types.int;
              default = 3;
              description = "Number of fingers required for swipe gesture";
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];

            launchd.user.agents.aerospace-swipe = {
              serviceConfig = {
                Label = "com.acsandmann.swipe";
                ProgramArguments = [
                  "${cfg.package}/Applications/AerospaceSwipe.app/Contents/MacOS/AerospaceSwipe"
                ];
                RunAtLoad = true;
                KeepAlive = true;
                StandardOutPath = "/tmp/aerospace-swipe.log";
                StandardErrorPath = "/tmp/aerospace-swipe.err";
              };
            };
          };
        };
    };
}
