{ lib, stdenvNoCC, makeWrapper
, bash, coreutils, findutils, gawk, gnugrep, gnused
, inotify-tools, jq, podman, shadow, getent
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
    getent        # getent (NSS lookups)
    gnugrep       # grep
    gnused        # sed
    inotify-tools # inotifywait
    jq            # jq
    podman        # podman
    shadow        # groupadd, useradd, usermod, nologin
  ];
in
stdenvNoCC.mkDerivation {
  pname = "contain-scripts";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = [ makeWrapper ];

  inherit runtimeDeps;  # expose as derivation attribute for introspection

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    # ── lib/ scripts (runtime helpers invoked by systemd services) ──
    install -Dm755 lib/contain-watcher.sh "$out/lib/contain/contain-watcher.sh"
    install -Dm755 lib/contain-commit.sh  "$out/lib/contain/contain-commit.sh"

    # ── scripts/ (admin / setup tools) ──
    install -Dm755 scripts/prepare-permissions.sh "$out/bin/contain-prepare-permissions"

    # ── Wrap every installed script with the full runtime PATH ──
    for f in \
      "$out/lib/contain/contain-watcher.sh" \
      "$out/lib/contain/contain-commit.sh" \
      "$out/bin/contain-prepare-permissions" \
    ; do
      wrapProgram "$f" \
        --prefix PATH : "${lib.makeBinPath runtimeDeps}"
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "contain helper scripts with Nix-wrapped PATH";
    license     = licenses.cc-by-nc-40;
    platforms   = platforms.linux;
  };
}
