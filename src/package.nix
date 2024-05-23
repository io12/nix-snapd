{
  pkgs,
  lib,
  stdenv,
  python3,
  xdg-utils,
  writeTextDir,
  fetchFromGitHub,
  buildGoModule,
  buildFHSEnvBubblewrap,
  snapConfineWrapper ? null,
}:

let
  version = "2.62";

  src = fetchFromGitHub {
    owner = "snapcore";
    repo = "snapd";
    rev = version;
    hash = "sha256-4tUbPqAoaXmJIIMhnVZX+f2P2Wc+EUFR/d/yAxAKK80=";
  };

  goModules =
    (buildGoModule {
      pname = "snap-go-mod";
      inherit version src;
      vendorHash = "sha256-1l04iE849WpIBFePEUjJcIP5akVLGy2mT1reGJCwoiM=";
    }).goModules;

  env = buildFHSEnvBubblewrap {
    name = "snap-env";
    extraBwrapArgs = [
      "--bind /var/snap /var/snap"
      "--bind /snap /snap"
      "--bind-try /etc/oracle-cloud-agent /etc/oracle-cloud-agent"
    ];
    targetPkgs = pkgs:
      (with pkgs; [
        # Snapd calls
        util-linux.mount
        squashfsTools
        systemd
        openssh
        gnutar
        gzip
        # TODO: xdelta

        # Snap hook calls
        bash
        sudo
        gawk

        # Mount wrapper calls
        coreutils
      ]);
  };
in
stdenv.mkDerivation {
  pname = "snap";
  inherit version src;

  nativeBuildInputs = with pkgs; [
    makeWrapper
    autoconf
    automake
    autoconf-archive
  ];

  buildInputs = with pkgs; [
    go
    glibc
    glibc.static
    pkg-config
    libseccomp
    libxfs
    libcap
    glib
    udev
    libapparmor
  ];

  patches = [ ./nixify.patch ];

  configurePhase = ''
    substituteInPlace $(grep -rl '@out@') --subst-var 'out'

    export GOCACHE=$TMPDIR/go-cache

    ln -s ${goModules} vendor

    ./mkversion.sh $version

    (
      cd cmd
      autoreconf -i -f
      ./configure \
        --prefix=$out \
        --libexecdir=$out/libexec/snapd \
        --with-snap-mount-dir=/snap \
        --enable-apparmor \
        --enable-nvidia-biarch \
        --enable-merged-usr
    )

    mkdir build
    cd build
  '';

  makeFlagsPackaging = [
    "--makefile=../packaging/snapd.mk"
    "SNAPD_DEFINES_DIR=${writeTextDir "snapd.defines.mk" ""}"
    "snap_mount_dir=$(out)/snap"
    "bindir=$(out)/bin"
    "sbindir=$(out)/sbin"
    "libexecdir=$(out)/libexec"
    "mandir=$(out)/share/man"
    "datadir=$(out)/share"
    "localstatedir=$(TMPDIR)/localstatedir"
    "sharedstatedir=$(TMPDIR)/sharedstatedir"
    "unitdir=$(out)/unitdir"
    "builddir=."
    "with_testkeys=1"
    "with_apparmor=1"
    "with_core_bits=0"
    "with_alt_snap_mount_dir=0"
  ];

  makeFlagsData = [
    "--directory=../data"
    "BINDIR=$(out)/bin"
    "LIBEXECDIR=$(out)/libexec"
    "DATADIR=$(out)/share"
    "SYSTEMDSYSTEMUNITDIR=$(out)/lib/systemd/system"
    "SYSTEMDUSERUNITDIR=$(out)/lib/systemd/user"
    "ENVD=$(out)/etc/profile.d"
    "DBUSDIR=$(out)/share/dbus-1"
    "APPLICATIONSDIR=$(out)/share/applications"
    "SYSCONFXDGAUTOSTARTDIR=$(out)/etc/xdg/autostart"
    "ICON_FOLDER=$(out)/share/snapd"
  ];

  makeFlagsCmd = [
    "--directory=../cmd"
    "SYSTEMD_SYSTEM_GENERATOR_DIR=$out/lib/systemd/system-generators"
  ];

  buildPhase = ''
    make $makeFlagsPackaging all
    make $makeFlagsData all
    make $makeFlagsCmd all
  '';

  installPhase = ''
    make $makeFlagsPackaging install
    make $makeFlagsData install
    make $makeFlagsCmd install
  '';

  postFixup = ''
    mv $out/libexec/snapd/snap-confine{,-unwrapped}

    ${
      if builtins.isNull snapConfineWrapper then
        "ln -s snap-confine-stage-1 $out/libexec/snapd/snap-confine"
      else
        "ln -s ${snapConfineWrapper} $out/libexec/snapd/snap-confine"
    }

    cat > $out/libexec/snapd/snap-confine-stage-1 << EOL
    #!${python3}/bin/python3
    import sys, os, json
    os.environ["NIX_SNAP_CONFINE_DATA"] = json.dumps(dict(
      uid=os.getuid(),
      gid=os.getgid(),
      args=sys.argv[1:],
    ))
    os.setuid(0)
    os.setgid(0)
    os.execv(
      "${env}/bin/snap-env",
      [
        "${env}/bin/snap-env",
        "-c",
        "exec @out@/libexec/snapd/snap-confine-stage-2",
      ],
    )
    EOL
    substituteInPlace $out/libexec/snapd/snap-confine-stage-1 --subst-var 'out'
    chmod +x $out/libexec/snapd/snap-confine-stage-1

    cat > $out/libexec/snapd/snap-confine-stage-2 << EOL
    #!${python3}/bin/python3
    import sys, os, json
    data = json.loads(os.environ.pop("NIX_SNAP_CONFINE_DATA"))
    os.setresuid(data["uid"], 0, 0)
    os.setresgid(data["gid"], 0, 0)
    os.environ["PATH"] += ":@out@/bin"
    unwrapped = "@out@/libexec/snapd/snap-confine-unwrapped"
    os.execv(unwrapped, [unwrapped] + data["args"])
    EOL
    substituteInPlace $out/libexec/snapd/snap-confine-stage-? --subst-var 'out'
    chmod +x $out/libexec/snapd/snap-confine-stage-2

    # Make xdg-open wrapper for io.snapcraft.Launcher so it can run xdg-open to
    # open with any installed program, even if it isn't a dependency
    makeWrapper ${xdg-utils}/bin/xdg-open $out/libexec/xdg-open \
      --suffix PATH : /run/current-system/sw/bin

    wrapProgram $out/libexec/snapd/snapd \
      --set SNAPD_DEBUG 1 \
      --set PATH $out/bin:${
        lib.makeBinPath (
          with pkgs;
          [
            # Snapd calls
            util-linux.mount
            shadow
            squashfsTools
            systemd
            openssh
            gnutar
            gzip
            # TODO: xdelta

            # Snap hook calls
            bash
            sudo
            gawk

            # Mount wrapper calls
            coreutils
          ]
        )
      } \
      --run ${lib.escapeShellArg ''
        set -uex
        shopt -s nullglob

        # Pre-create directories
        install -dm755 /var/lib/snapd/snaps
        install -dm111 /var/lib/snapd/void

        # Upstream snapd writes unit files to /etc/systemd/system, which is
        # immutable on NixOS. This package works around that by patching snapd
        # to write the unit files to /var/lib/snapd/nix-systemd-system
        # instead, and enables them as transient runtime units. However, this
        # means they won't automatically start on boot, which breaks snapd.
        # To solve this, the next block of code first symlinks all the
        # mount units and then starts all the unit files in
        # /var/lib/snapd/nix-systemd-system.
        for path in /var/lib/snapd/nix-systemd-system/*.mount; do
          name="$(basename "$path")"
          rtpath="/run/systemd/system/$name"
          ln -fs "$path" "$rtpath"
        done
        for path in /var/lib/snapd/nix-systemd-system/*.service; do
          name="$(basename "$path")"
          if ! systemctl is-active --quiet "$name"; then
            rtpath="/run/systemd/system/$name"
            ln -fs "$path" "$rtpath"
            systemctl start "$name"
            rm -f "$rtpath"
          fi
        done

        # Make /snap/bin symlinks not point inside /nix/store,
        # so they don't point to an old version of snap
        for f in /snap/bin/*; do
          if [[ "$(readlink "$f")" = /nix/store/* ]]; then
            rm -f "$f"
            ln -s /run/current-system/sw/bin/snap "$f"
          fi
        done
      ''}
  '';
}
