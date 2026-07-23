{ ... }:
{
  name = "uefi-capsule-update";

  nodes.machine =
    { pkgs, ... }:
    let
      uboot =
        if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
          # Default environment for qemu-arm64 uboot does not work well with
          # large nixos kernel/initrds.
          {
            uboot = pkgs.ubootQemuAarch64.overrideAttrs (old: {
              extraConfig = (old.extraConfig or "") + ''
                CONFIG_EFI_CAPSULE_ON_DISK=y
                CONFIG_EFI_RUNTIME_UPDATE_CAPSULE=y
                CONFIG_EFI_CAPSULE_FIRMWARE_RAW=y
                CONFIG_TOOLS_MKEFICAPSULE=y
                CONFIG_TOOLS_LIBCRYPTO=y
              '';

              postPatch = (old.postPatch or "") + ''
                substituteInPlace board/emulation/qemu-arm/qemu-arm.env \
                  --replace-fail "kernel_addr_r=0x40400000" "kernel_addr_r=0x50000000" \
                  --replace-fail "ramdisk_addr_r=0x44000000" "ramdisk_addr_r=0x58000000"
              '';

              postInstall = (old.postInstall or "") + ''
                ./tools/mkeficapsule \
                  --index 1 --instance 0 \
                  --guid 058b7d83-50d5-4c47-a195-60d86ad341c4 \
                  u-boot.bin $out/UBOOT.cap
              '';
            });
            firmware = "u-boot.bin";

            capsuleUboot = uboot.overrideAttrs (old: {
              extraConfig = (old.extraConfig or "") + ''
                CONFIG_LOCALVERSION="-nixos-updated"
              '';
            });
          }
        else if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
          rec {
            uboot = pkgs.ubootQemuX86_64.overrideAttrs (old: {
              extraConfig = (old.extraConfig or "") + ''
                CONFIG_EFI_CAPSULE_ON_DISK=y
                CONFIG_EFI_RUNTIME_UPDATE_CAPSULE=y
                CONFIG_EFI_CAPSULE_FIRMWARE_RAW=y
                CONFIG_TOOLS_MKEFICAPSULE=y
                CONFIG_TOOLS_LIBCRYPTO=y
              '';

              patches = (old.patches or []) ++ [
                # series to support capsule updates on qemu x86_64
                (pkgs.fetchpatch {
                  url = "https://patchwork.ozlabs.org/series/516443/mbox/";
                  sha256 = "sha256-SBLcat7Cp90Nm0l2GJ9AbQHsTXRghJcB8vGn0A7HTOc=";
                })
              ];

              postInstall = (old.postInstall or "") + ''
                ./tools/mkeficapsule \
                  --index 1 --instance 0 \
                  --guid 5bb9ce0d-a389-456f-83a8-2bdfb8ad01a1 \
                  u-boot.bin $out/UBOOT.cap
              '';
            });
            firmware = "u-boot.rom";

            capsuleUboot = uboot.overrideAttrs (old: {
              extraConfig = (old.extraConfig or "") + ''
                CONFIG_LOCALVERSION="-nixos-updated"
              '';
            });
          }
        else
          throw "unsupported platform";
    in
    {
      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        efi = {
          firmware = "${uboot.uboot}/${uboot.firmware}";
          mutableFirmware = true;
        };
        cores = 2;
      };

      boot.loader.systemd-boot.enable = true;

      environment.systemPackages = [
        (pkgs.writeShellApplication {
          name = "install-capsule";
          text = ''
            mkdir -p /boot/EFI/UpdateCapsule/
            cp ${uboot.capsuleUboot}/UBOOT.cap /boot/EFI/UpdateCapsule/
          '';
        })
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("install-capsule")
    # We can't do `machine.succeed("reboot")` because it the command doesn't exit
    # from perspective of runner (the VM restarts)
    machine.shutdown()
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    assert "-nixos-updated" in machine.succeed("cat /sys/devices/virtual/dmi/id/bios_version")
  '';
}
