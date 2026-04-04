{ lib, stdenvNoCC, makeWrapper
, bash, coreutils, findutils, gawk, gnugrep, gnused
, inotify-tools, jq, podman, shadow
}:

# Packages the helper scripts from lib/ and scripts/ with wrapped PATH so
# every external command they invoke is resolved from the Nix store rather
# than relying on ambient $PATH.

let
  # Runtime dependencies injected into each wrapper's PATH.
  runtimeDeps = [
    bash
    coreutils     # id, stat, chmod, chown, chgrp, mkdir, install, cp,
                  # sort, tail, cut, date, basename, logname
    findutils     # find, xargs
    gawk          # awk
    gnugrep       # grep
    gnused        # sed
    inotify-tools # inotifywait
    jq            # jq
    podman        # podman
    shadow        # groupadd, useradd, usermod, getent, nologin
  ];
in
stdenvNoCC.mkDerivation {
  pname = "cont-ai-nerd-scripts";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = [ makeWrapper ];

  inherit runtimeDeps;  # expose as derivation attribute for introspection

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # ── lib/ scripts (runtime helpers invoked by systemd services) ──
    install -Dm755 lib/cont-ai-nerd-watcher.sh "$out/lib/cont-ai-nerd/cont-ai-nerd-watcher.sh"
    install -Dm755 lib/cont-ai-nerd-commit.sh  "$out/lib/cont-ai-nerd/cont-ai-nerd-commit.sh"

    # ── scripts/ (admin / setup tools) ──
    install -Dm755 scripts/prepare-permissions.sh "$out/bin/cont-ai-nerd-prepare-permissions"

    # ── Wrap every installed script with the full runtime PATH ──
    for f in \
      "$out/lib/cont-ai-nerd/cont-ai-nerd-watcher.sh" \
      "$out/lib/cont-ai-nerd/cont-ai-nerd-commit.sh" \
      "$out/bin/cont-ai-nerd-prepare-permissions" \
    ; do
      wrapProgram "$f" \
        --prefix PATH : "${lib.makeBinPath runtimeDeps}"
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "cont-ai-nerd helper scripts with Nix-wrapped PATH";
    license     = licenses.cc-by-nc-40;
    platforms   = platforms.linux;
  };
}
