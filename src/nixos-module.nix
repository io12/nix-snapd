self:

{ pkgs, config, lib, ... }:

let
  cfg = config.services.snap;

  snap = self.packages.x86_64-linux.default.override {
    snapConfineWrapper = "${config.security.wrapperDir}/snap-confine-stage-1";
  };

in {
  options.services.snap = {
    enable = lib.mkEnableOption "snap service";

    snapBinInPath = lib.mkOption {
      default = true;
      example = false;
      description = "Include /snap/bin in PATH.";
      type = lib.types.bool;
    };

    desktopFiles = lib.mkOption {
      default = true;
      example = false;
      description =
        "Add desktop files for opening snaps in desktop environments.";
      type = lib.types.bool;
    };
  };

  config = lib.mkIf cfg.enable {
    security.apparmor = {
      enable = true;
      packages = [ snap ];
      policies."libexec.snapd.snap-confine".profile =
        "include ${snap}/etc/apparmor.d/usr.libexec.snapd.snap-confine";
    };

    environment.systemPackages = [ snap ];

    environment.extraInit = ''
      ${lib.optionalString cfg.snapBinInPath ''
        export PATH="/snap/bin:$PATH"
      ''}

      ${lib.optionalString cfg.desktopFiles ''
        export XDG_DATA_DIRS="/var/lib/snapd/desktop:$XDG_DATA_DIRS"
      ''}
    '';

    systemd = {
      packages = [ snap ];
      sockets.snapd.wantedBy = [ "sockets.target" ];
      services.snapd.wantedBy = [ "multi-user.target" ];
      services.nix-snapd-precreate = {
        wantedBy = [ "apparmor.service" ];
        before = [ "apparmor.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart =
            "${pkgs.coreutils}/bin/mkdir -p /var/lib/snapd/apparmor/snap-confine";
        };
      };
    };

    security.wrappers.snap-confine-stage-1 = {
      setuid = true;
      owner = "root";
      group = "root";
      source = "${snap}/libexec/snapd/snap-confine-stage-1";
    };
  };
}
