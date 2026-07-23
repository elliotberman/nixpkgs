{ ... }:
{
  name = "uboot EFI boot";

  nodes.machine =
    { pkgs, ... }:
    let
      firmware =
        if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
          # Default environment for qemu-arm64 uboot does not work well with
          # large nixos kernel/initrds.
          pkgs.ubootQemuAarch64.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace board/emulation/qemu-arm/qemu-arm.env \
                --replace-fail "kernel_addr_r=0x40400000" "kernel_addr_r=0x50000000" \
                --replace-fail "ramdisk_addr_r=0x44000000" "ramdisk_addr_r=0x58000000"
            '';
          }) + "/u-boot.bin"
        else if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
          "${pkgs.ubootQemuX86_64}/u-boot.rom"
        else
          throw "unsupported platform";
    in
    {
      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        efi = {
          inherit firmware;
          keepVariables = false;
        };
        cores = 2;
      };

      # GRUB doesn't install to the default location and we don't have persistent
      # EFI variables, so GRUB won't boot without explicitly pointing U-Boot to it
      # systemd-boot will install to BOOT{X64/AA64}.EFI which U-Boot can figure out
      # on its own because EFI spec says that's where bootloader should be.
      boot.loader.systemd-boot.enable = true;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    assert "U-Boot" in machine.succeed("cat /sys/devices/virtual/dmi/id/bios_vendor")
  '';
}
