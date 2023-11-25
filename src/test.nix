{ self, pkgs }:

let
  nixos-lib = import "${pkgs.path}/nixos/lib" { };

  snap = self.packages.x86_64-linux.default;

  # Download tested snaps with a fixed-output derivation because the test runner
  # normally doesn't have internet access
  downloadedSnaps = pkgs.runCommand "downloaded-snaps" {
    buildInputs = [ snap pkgs.squashfsTools ];
    outputHashMode = "recursive";
    outputHash = "sha256-21rxObL/SlKg2UHudWtyQcgxS0CwLN0nijztC1669qQ=";
  } ''
    mkdir $out
    cd $out

    snap download --revision=16202 core
    snap download --revision=2796 core18
    snap download --revision=2015 core20
    snap download --revision=864 core22
    snap download --revision=5 bare
    snap download --revision=141 gnome-42-2204
    snap download --revision=1535 gtk-common-themes
    snap download --revision=29 hello-world
    snap download --revision=9 ripgrep
    snap download --revision=6089 microk8s
    snap download --revision=955 gnome-calculator
  '';

in nixos-lib.runTest {
  name = "snap";
  hostPkgs = pkgs;

  nodes.machine = {
    imports = [
      (import "${pkgs.path}/nixos/tests/common/user-account.nix")
      (import "${pkgs.path}/nixos/tests/common/x11.nix")
      self.nixosModules.default
    ];
    virtualisation.diskSize = 2048;
    test-support.displayManager.auto.user = "alice";
    services.snap.enable = true;
  };

  enableOCR = true;

  testScript = ''
    # Check version
    assert "${snap.version}" in machine.succeed("snap --version")

    def install(name_rev, classic=False):
      classic = "--classic" if classic else ""
      machine.succeed(f"snap ack ${downloadedSnaps}/{name_rev}.assert")
      machine.succeed(f"snap install {classic} ${downloadedSnaps}/{name_rev}.snap")

    # Ensure snap programs aren't already installed
    machine.fail("hello-world")
    machine.fail("rg --version")
    machine.fail("microk8s version")
    machine.fail("gnome-calculator")

    # Install snaps
    install("core_16202")
    install("core18_2796")
    install("core20_2015")
    install("core22_864")
    install("bare_5")
    install("gnome-42-2204_141")
    install("gtk-common-themes_1535")
    install("hello-world_29")
    install("ripgrep_9", classic=True)
    # install("microk8s_6089", classic=True)
    install("gnome-calculator_955")

    def run():
      machine.wait_for_unit("snapd.service")

      assert machine.succeed("hello-world") == "Hello World!\n"
      assert "ripgrep 12.1.0" in machine.succeed("rg --version")
      # assert machine.succeed("microk8s version") == "MicroK8s v1.28.3 revision 6089\n"

      # Test gnome-calculator snap
      machine.wait_for_x()
      machine.succeed("su - alice -c '${pkgs.xorg.xhost}/bin/xhost si:localuser:alice'")
      machine.succeed("su - alice -c '${pkgs.xorg.xhost}/bin/xhost si:localuser:root'")
      assert "Basic" not in machine.get_screen_text()
      machine.execute("su - alice -c gnome-calculator >&2 &")
      machine.wait_for_text("Basic")
      assert "Basic" in machine.get_screen_text()
      machine.screenshot("gnome-calculator")

    # Ensure programs run after a crash or clean reboot
    run()
    machine.crash()
    run()
    machine.shutdown()
    run()

    # Ensure uninstalling snaps works
    machine.succeed("snap remove hello-world")
    machine.fail("hello-world")
  '';
}
