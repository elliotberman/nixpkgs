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

            badUboot = uboot.out.overrideAttrs (old: {
              postInstall = (old.postInstall or "") + ''
                # Wrong GUID
                ./tools/mkeficapsule \
                  --index 1 --instance 0 \
                  --guid 5bb9ce0d-a389-456f-83a8-2bdfb8ad01a0 \
                  u-boot.bin $out/uki-stuff/uboot/UBOOT.cap
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
          rev = "4b9583d295659ac3c355704559166a7ae1823b3c";
          hash = "sha256-lsSeAuLfKSnDRqIvcBklyu7BaAQ7iVxy/+w35pqBwEw=";
        };

        patches = [
        ../../pkgs/os-specific/linux/systemd/0001-Don-t-try-to-unmount-nix-or-nix-store.patch
        ./systemd-patch
        ../../pkgs/os-specific/linux/systemd/0003-add-rootprefix-to-lookup-dir-paths.patch
        ../../pkgs/os-specific/linux/systemd/0004-path-util.h-add-placeholder-for-DEFAULT_PATH_NORMAL.patch
        ../../pkgs/os-specific/linux/systemd/0005-core-don-t-taint-on-unmerged-usr.patch
        ../../pkgs/os-specific/linux/systemd/0006-timesyncd-disable-NSCD-when-DNSSEC-validation-is-dis.patch
        ];
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
              SizeMinBytes = "128M";
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
              config.specialisation.bad.configuration.system.build.toplevel
              config.specialisation.bad.configuration.system.build.uki
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
      boot.uki.tries = 2;
      system.image.version = "1";
      boot.uki.settings = {
        UKI = {
          HWIDs = "${uboot.uboot}/uki-stuff";
          Firmware = "${uboot.uboot}/uki-stuff/uboot";
        };
      };

      specialisation.updated.configuration = {
        system.image.version = lib.mkForce "2";
        boot.uki.settings = {
          UKI = {
            HWIDS = lib.mkForce "${uboot.updatedUboot}/uki-stuff";
            Firmware = lib.mkForce "${uboot.updatedUboot}/uki-stuff/uboot";
          };
        };
      };

      specialisation.bad.configuration = {
        system.image.version = lib.mkForce "3";
        boot.uki.settings = {
          UKI = {
            HWIDS = lib.mkForce "${uboot.badUboot}/uki-stuff";
            Firmware = lib.mkForce "${uboot.badUboot}/uki-stuff/uboot";
          };
        };
      };
    };

  testScript = { nodes, ... }:
  let
    newCfg = nodes.machine.specialisation.updated.configuration;
    newUki = "${newCfg.system.build.uki}/${newCfg.system.boot.loader.ukiFile}";
    newUkiFile = newCfg.system.boot.loader.ukiFile;
    badCfg = nodes.machine.specialisation.bad.configuration;
    badUki = "${badCfg.system.build.uki}/${badCfg.system.boot.loader.ukiFile}";
    badUkiFile = badCfg.system.boot.loader.ukiFile;
    badUkiName = "${badCfg.boot.uki.name}_${badCfg.system.image.version}";
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

    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    with subtest("capsule update works"):
        # install the new UKI (higher version -> preferred by systemd-boot)
        machine.succeed("cp ${newUki} /boot/EFI/Linux/${newUkiFile}")
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        assert "-nixos-updated" in machine.succeed("cat /sys/devices/virtual/dmi/id/bios_version")

    with subtest("bad UKI is skipped after exhausting boot counter"):
        # The bad UKI carries a wrong-GUID capsule; its firmware-update service
        # fails before boot-complete.target, so it is never blessed. It has the
        # highest version, so systemd-boot tries it first. After `tries` failed
        # boots its counter is exhausted (+0-2) and it is skipped, falling back to
        # the last-known-good (updated) UKI.
        machine.succeed("cp ${badUki} /boot/EFI/Linux/${badUkiFile}")
        machine.reboot()
        machine.wait_for_unit("multi-user.target")
        # bad capsule never applied -> firmware is still the updated one
        assert "-nixos-updated" in machine.succeed("cat /sys/devices/virtual/dmi/id/bios_version")
        # bad UKI's boot counter is exhausted, proving it was skipped
        machine.succeed("test -e /boot/EFI/Linux/${badUkiName}+0-2.efi")
  '';
}
