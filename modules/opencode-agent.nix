{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.opencode-agent;

  # Dynamically generate the JSON policy based on authorized paths
  opencodeJson = pkgs.writeText "opencode.json" (builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    permission = {
      external_directory = listToAttrs (map (path: {
        name = "${path}/**";
        value = "allow";
      }) cfg.projectPaths);
    };
  });

in {
  options.services.opencode-agent = {
    enable = mkEnableOption "Opencode Sandboxed AI Agent";

    primaryUser = mkOption {
      type = types.str;
      description = "The primary host user to associate with the ai group.";
    };

    executable = mkOption {
      type = types.str;
      default = "/opt/opencode/opencode";
      description = "Absolute path to the opencode binary.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Network interface to bind.";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Network port to bind.";
    };

    projectPaths = mkOption {
      type = types.listOf types.str;
      description = "List of absolute paths to explicitly bind into the isolated environment.";
    };
  };

  config = mkIf cfg.enable {

    # 1. Identity & Group Provisioning
    users.groups.ai = {};
    
    users.users.agent = {
      isSystemUser = true;
      group = "ai";
      home = "/var/lib/opencode/workspace";
      createHome = true;
      shell = pkgs.shadow.nologin;
    };

    users.users.${cfg.primaryUser}.extraGroups = [ "ai" ];

    # 2. Filesystem State & Group Inheritance (replaces imperative setfacl/chgrp)
    systemd.tmpfiles.rules = 
      # Set group ownership and the SetGID (2775) bit for authorized project paths
      (map (path: "d ${path} - ${cfg.primaryUser} ai -") cfg.projectPaths) ++ [
      # Ensure workspace directory exists with strict ownership
      "d /var/lib/opencode/workspace 0750 agent ai -"
    ];

    # 3. Systemd Unit Generation
    systemd.services.opencode-agent = {
      description = "Opencode AI Agent (Sandboxed Daemon)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # Initialization: Copy the read-only Nix store JSON policy into the mutable workspace
      preStart = ''
        ${pkgs.coreutils}/bin/cp ${opencodeJson} /var/lib/opencode/workspace/opencode.json
        ${pkgs.coreutils}/bin/chown agent:ai /var/lib/opencode/workspace/opencode.json
        ${pkgs.coreutils}/bin/chmod 640 /var/lib/opencode/workspace/opencode.json
      '';

      serviceConfig = {
        Type = "simple";
        User = "agent";
        Group = "ai";
        WorkingDirectory = "/var/lib/opencode/workspace";
        
        ExecStart = "${cfg.executable} --hostname ${cfg.host} --port ${toString cfg.port}";
        
        Restart = "on-failure";
        StandardOutput = "null";
        # StandardError is omitted; NixOS naturally routes stderr to the systemd journal.

        # Security and Filesystem Isolation
        NoNewPrivileges = true;
        ProtectSystem = "full";
        PrivateTmp = true;

        # Mask the host /home directory
        ProtectHome = "tmpfs";

        # Explicitly bind allowed paths into the empty tmpfs
        BindPaths = cfg.projectPaths;

        # Bind the primary user's opencode data directory read-only (auth credentials)
        BindReadOnlyPaths = [ "/home/${cfg.primaryUser}/.local/share/opencode" ];

        # Resource limits for unmanaged shell execution mitigation
        MemoryMax = "2G";
        TasksMax = 100;
      };
    };
  };
}
