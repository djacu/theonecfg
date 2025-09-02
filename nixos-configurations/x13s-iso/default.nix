{
  release = "jfly";
  modules =
    {
      modulesPath,
      pkgs,
      ...
    }:
    {

      imports = [
        (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")

        # Provide an initial copy of the NixOS channel so that the user
        # doesn't need to run "nix-channel --update" first.
        (modulesPath + "/installer/cd-dvd/channel.nix")
      ];

      hardware.deviceTree.name = "qcom/sc8280xp-lenovo-thinkpad-x13s.dtb";

      nixpkgs.buildPlatform = "x86_64-linux";
      nixpkgs.hostPlatform = "aarch64-linux";

      environment.systemPackages = [ pkgs.vim ];

      boot.kernelPackages = pkgs.linuxPackages_6_16;

      # https://github.com/jhovold/linux/wiki/X13s#kernel-command-line
      # To boot Linux the following kernel parameters need to be provided:
      boot.kernelParams = [
        "clk_ignore_unused"
        "pd_ignore_unused"
        "arm64.nopauth"
        "efi=noruntime"
      ];

      # https://github.com/jhovold/linux/commit/27ec0c77d3cc0e56ad24088c40568a44794c54b4
      # Make sure the initramfs includes any modules required to boot, for example:
      boot.initrd.availableKernelModules = [

        # for the X13s
        # specifically for nvme
        "nvme"
        "phy_qcom_qmp_pcie"
        # "pcie_qcom" # this is already built into the kernel arm64 defconfig and is not needed

        # For keyboard input and (more than 30 seconds of) display in initramfs, make sure to also include
        # for keyboard
        "i2c_hid_of"
        "i2c_qcom_geni"
        # for the display
        "leds_qcom_lpg"
        "pwm_bl"
        "qrtr"
        "pmic_glink_altmode"
        "gpio_sbu_mux"
        "phy_qcom_qmp_combo"
        "gpucc_sc8280xp"
        "dispcc_sc8280xp"
        "phy_qcom_edp"
        "panel_edp"
        "msm"

        # jmbaur said add all this
        "icc_bwmon"
        "lpasscc_sc8280xp"
        "phy_qcom_apq8064_sata"
        "phy_qcom_eusb2_repeater"
        "phy_qcom_ipq4019_usb"
        "phy_qcom_ipq806x_sata"
        "phy_qcom_ipq806x_usb"
        "phy_qcom_m31"
        "phy_qcom_pcie2"
        "phy_qcom_qmp_pcie_msm8996"
        "phy_qcom_qmp_ufs"
        "phy_qcom_qmp_usb"
        "phy_qcom_qmp_usb_legacy"
        "phy_qcom_qmp_usbc"
        "phy_qcom_qusb2"
        "phy_qcom_sgmii_eth"
        "phy_snps_eusb2"
        "phy_qcom_snps_femto_v2"
        "phy_qcom_usb_hs"
        "phy_qcom_usb_hs_28nm"
        "phy_qcom_usb_hsic"
        "phy_qcom_usb_ss"
        "pmic_glink"
        "qcom_glink_smem"
        "qcom_q6v5_pas" # This module loads a lot of FW blobs
        "qcom_rpm"
        "uas"
        "ucsi_glink"

      ];

    };
}
