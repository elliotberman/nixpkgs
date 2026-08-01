# To run this test, install nix
# Clone this repo/commit
# `nix run .#nixosTests.systemd-uki-fw-capsule`
{ lib, ... }:
{
  name = "systemd-uki-fw-capsule";

  nodes.machine =
    { config, pkgs, ... }:
    let
      # Use U-boot as the backing firmware primarily because it was the easiest
      # to get capsule updates working. OVMF doesn't support capsule updates out
      # of the box, and it was easier for me to figure out what to do for U-boot
      uboot =
        if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
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

              # { "chidType": "HardwareID02", "data": { "manufacturer": "qemu", "product_name": "QEMU x86 (I440FX)", "bios_vendor": "U-Boot", "version": "2026.07", "major_version": "1a", "minor_version": "07" } }
              env = (old.env or { }) // { hwid = "7866f76c-41bb-50ea-a874-8a436b2a3eb6"; };

              postInstall = (old.postInstall or "") + ''
                mkdir -p $out/uki-stuff/uboot

                ./tools/mkeficapsule \
                  --index 1 --instance 0 \
                  --guid 5bb9ce0d-a389-456f-83a8-2bdfb8ad01a1 \
                  u-boot.bin $out/uki-stuff/uboot/UBOOT.cap

                echo $hwid >$out/uki-stuff/uboot/hwid

                echo '${builtins.toJSON {
                  type = "uefi-fw";
                  name = "U-BOOT VM";
                  hwids = [
                    # HWID05 for "manufacturer": "qemu", "family": "", "product_name": "QEMU x86 (I440FX)"
                    "bc1c5127-b8c4-5606-ac5a-1f528595bee2"
                  ];
                  fwid = "uboot";
                }}' > $out/uki-stuff/hwids.json
              '';
            });

            firmware = "u-boot.rom";

            updatedUboot = uboot.out.overrideAttrs (old: {
              # { "chidType": "HardwareID02", "data": { "manufacturer": "qemu", "product_name": "QEMU x86 (I440FX)", "bios_vendor": "U-Boot", "version": "2026.07-nixos-updated", "major_version": "1a", "minor_version": "07" } }
              env = (old.env or { }) // { hwid = "a725b8d0-b876-5c54-8dcd-0e400e2aa7cf"; };
              extraConfig = (old.extraConfig or "") + ''
                CONFIG_LOCALVERSION="-nixos-updated"
              '';
            });
          }
        # TODO: aarch64 support, mostly copy/paste of above but with ubootQemuAarch64, figuring out the HWIDs, running the test
        else
          throw "unsupported platform";
    in
    {
      imports = [ ../modules/image/repart.nix ];

      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        efi = {
          firmware = "${uboot.uboot}/${uboot.firmware}";
          mutableFirmware = true;
        };
        cores = 2;
      };

      ##########################################################################
      # source overrides for systemd
      systemd.package = (pkgs.systemd.overrideAttrs {
        src = pkgs.fetchFromGitHub {
          owner = "elliotberman";
          repo = "systemd";
          # branch = "efifw-capsules";
          rev = "61f554852b9e28c80f21993d6324b4da828b3155";
          hash = "sha256-Z62Uq3LIleAjKEEjeh33GEy0FFsp0gAhn7R+zAp2S+I=";
        };
      }).override {
        withUkify = true;
      };
      system.build.uki = lib.mkForce (pkgs.runCommand config.system.boot.loader.ukiFile { } ''
        mkdir -p $out
        ${config.systemd.package}/lib/systemd/ukify build \
          --config=${config.boot.uki.configFile} \
          --output="$out/${config.system.boot.loader.ukiFile}"
      '');
      ##########################################################################

      boot.loader.systemd-boot.enable = true;

      virtualisation.fileSystems = lib.mkForce {
        "/" = {
          device = "/dev/disk/by-partlabel/root";
          fsType = "ext4";
        };
        "/boot" = {
          device = "/dev/disk/by-partlabel/esp";
          fsType = "vfat";
        };
      };

      image.repart = {
        name = "appliance-gpt-image";
        sectorSize = 512;
        partitions = {
          "esp" = {
            contents =
              let
                efiArch = config.nixpkgs.hostPlatform.efiArch;
              in
              {
                "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
                  "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

                "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
                  "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
              };
            repartConfig = {
              Type = "esp";
              Format = "vfat";
              Label = "esp";
              # Minimize = "guess" seems to not work very well for vfat
              # partitions. It's better to set a sensible default instead. The
              # aarch64 kernel seems to generally be a little bigger than the
              # x86_64 kernel. To stay on the safe side, leave some more slack
              # for every platform other than x86_64.
              SizeMinBytes = if config.nixpkgs.hostPlatform.isx86_64 then "64M" else "96M";
            };
          };
          "swap" = {
            repartConfig = {
              Type = "swap";
              Format = "swap";
              SizeMinBytes = "10M";
              SizeMaxBytes = "10M";
            };
          };
          "root" = {
            storePaths = [
              config.system.build.toplevel
              config.specialisation.updated.configuration.system.build.toplevel
              config.specialisation.updated.configuration.system.build.uki
            ];
            repartConfig = {
              Type = "root";
              Format = config.fileSystems."/".fsType;
              Label = "root";
              Minimize = "guess";
            };
          };
        };
      };

      ##########################################################################
      boot.uki.settings = {
        UKI = {
          HWIDs = "${uboot.uboot}/uki-stuff";
          Firmware = "${uboot.uboot}/uki-stuff/uboot";
        };
      };

      specialisation.updated.configuration = {
        boot.uki.settings = {
          UKI = {
            HWIDS = lib.mkForce "${uboot.updatedUboot}/uki-stuff";
            Firmware = lib.mkForce "${uboot.updatedUboot}/uki-stuff/uboot";
          };
        };
      };
    };

  testScript = { nodes, ... }:
  let
    newCfg = nodes.machine.specialisation.updated.configuration;
    newUki = "${newCfg.system.build.uki}/${newCfg.system.boot.loader.ukiFile}";
  in
  ''
    import os
    import subprocess
    import tempfile

    tmp_disk_image = tempfile.NamedTemporaryFile()

    subprocess.run([
      "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img",
      "create",
      "-f",
      "qcow2",
      "-b",
      "${nodes.machine.system.build.image}/${nodes.machine.image.filePath}",
      "-F",
      "raw",
      tmp_disk_image.name,
    ])

    # Set NIX_DISK_IMAGE so that the qemu script finds the right disk image.
    os.environ['NIX_DISK_IMAGE'] = tmp_disk_image.name

    machine.wait_for_unit("multi-user.target")

    # install the new UKI
    machine.succeed("cp ${newUki} /boot/EFI/Linux/${nodes.machine.system.boot.loader.ukiFile}")
    # We can't do `machine.succeed("reboot")` because it the command doesn't exit
    # from perspective of runner (the VM restarts)
    machine.shutdown()
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    assert "-nixos-updated" in machine.succeed("cat /sys/devices/virtual/dmi/id/bios_version")
  '';
}
