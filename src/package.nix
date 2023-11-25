{ pkgs, lib, stdenv, python3, writeTextDir, fetchFromGitHub, buildGoModule
, buildFHSEnvChroot, snapConfineWrapper ? null }:

let
  version = "2.61";

  src = fetchFromGitHub {
    owner = "snapcore";
    repo = "snapd";
    rev = version;
    hash = "sha256-xxPqKeFujM4hL0LW0PLG2ojL9fhEsYrj9qTr9iVDvRw=";
  };

  goModules = (buildGoModule {
    pname = "snap-go-mod";
    inherit version src;
    vendorHash = "sha256-DuvmnYl6ATBknSNzTCCyzYlLA0h+qo7ZmAED0mwIJkY=";
  }).goModules;

  env = buildFHSEnvChroot {
    name = "snap-env";
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

in stdenv.mkDerivation {
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

  inherit (pkgs)
    coreutils glibc readline ncurses libselinux pcre libapparmor udev libseccomp
    libcap;
  apparmor_parser = pkgs.apparmor-parser;
  util_linux = pkgs.util-linux.lib;
  dbus = pkgs.dbus.lib;

  configurePhase = ''
    substituteInPlace $(grep -rl '@out@') --subst-var out
    substituteInPlace sandbox/apparmor/apparmor.go --subst-var apparmor_parser
    substituteInPlace cmd/snap-confine/snap-confine.apparmor.in \
      --subst-var coreutils \
      --subst-var glibc \
      --subst-var readline \
      --subst-var ncurses \
      --subst-var libselinux \
      --subst-var pcre \
      --subst-var libapparmor \
      --subst-var udev \
      --subst-var libseccomp \
      --subst-var libcap \
      --subst-var util_linux \
      --subst-var dbus

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

    ${if builtins.isNull snapConfineWrapper then
      "ln -s snap-confine-stage-1 $out/libexec/snapd/snap-confine"
    else
      "ln -s ${snapConfineWrapper} $out/libexec/snapd/snap-confine"}

    cat > $out/libexec/snapd/snap-confine-stage-1 << EOL
    #!${python3}/bin/python3
    import sys, os
    uid = os.getuid()
    gid = os.getgid()
    os.setuid(0)
    os.setgid(0)
    os.execv(
      "${env}/bin/snap-env",
      [
        "${env}/bin/snap-env",
        "-c",
        " ".join([
          "exec",
          "@out@/libexec/snapd/snap-confine-stage-2",
          str(uid),
          str(gid),
          "@out@/libexec/snapd/snap-confine-unwrapped",
        ] + sys.argv[1:]),
      ],
    )
    EOL
    substituteInPlace $out/libexec/snapd/snap-confine-stage-1 --subst-var 'out'
    chmod +x $out/libexec/snapd/snap-confine-stage-1

    cat > $out/libexec/snapd/snap-confine-stage-2 << EOL
    #!${python3}/bin/python3
    import sys, os
    os.setresuid(int(sys.argv[1]), 0, 0)
    os.setresgid(int(sys.argv[2]), 0, 0)
    os.environ["PATH"] += ":@out@/bin"
    os.execv(sys.argv[3], sys.argv[3:])
    EOL
    substituteInPlace $out/libexec/snapd/snap-confine-stage-? --subst-var 'out'
    chmod +x $out/libexec/snapd/snap-confine-stage-2

    wrapProgram $out/libexec/snapd/snapd \
      --set SNAPD_DEBUG 1 \
      --set PATH $out/bin:${
        lib.makeBinPath (with pkgs; [
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
        ])
      } \
      --run ${
        lib.escapeShellArg ''
          set -uex
          shopt -s nullglob

          # Pre-create directories
          install -dm755 /var/lib/snapd/snaps
          install -dm111 /var/lib/snapd/void
          mkdir -p /var/lib/snapd/apparmor/snap-confine

          # Upstream snapd writes unit files to /etc/systemd/system, which is
          # immutable on NixOS. This package works around that by patching snapd
          # to write the unit files to /var/lib/snapd/nix-systemd-system
          # instead, and enables them as transient runtime units. However, this
          # means they won't automatically start on boot, which breaks snapd.
          # To solve this, the next block of code starts all the unit files in
          # /var/lib/snapd/nix-systemd-system.

          for path in /var/lib/snapd/nix-systemd-system/*; do
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
        ''
      }
  '';
}
