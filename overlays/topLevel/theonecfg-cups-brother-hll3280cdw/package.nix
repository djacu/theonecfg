{
  autoPatchelfHook,
  coreutils,
  dpkg,
  fetchurl,
  file,
  ghostscript,
  glibc,
  gnugrep,
  gnused,
  lib,
  libredirect,
  makeWrapper,
  perl,
  stdenv,
  which,
}:

let

  inherit (lib.strings)
    replaceString
    ;

  exactModel = "hl-l3280cdw";
  model = replaceString "-" "" exactModel;
  reldir = "opt/brother/Printers/${model}";

in

stdenv.mkDerivation (finalAttrs: {

  pname = "cups-brother-${model}";
  version = "3.5.1-1";

  src = fetchurl {
    url = "https://download.brother.com/welcome/dlf105735/${model}pdrv-${finalAttrs.version}.i386.deb";
    hash = "sha256-2JG7C+sC57f6+rKTWTjwnhvHrRp0qoFilQ/7KODNbr4=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
  ];

  buildInputs = [
    # coreutils
    ghostscript
    glibc
    # gnugrep
    # gnused
    makeWrapper
    perl
    # which
  ];

  unpackCmd = "dpkg-deb -x $curSrc source";

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r . $out
    # remove impure installer
    rm $out/${reldir}/cupswrapper/cupswrapperhll3280cdw

    runHook postInstall
  '';

  postFixup = ''

    basedir=$out/${reldir}/

    substituteInPlace $basedir/cupswrapper/brother_lpdwrapper_${model} \
      --replace-fail "basedir =~" "basedir = \"$basedir\"; #" \
      --replace-fail "PRINTER =~" "PRINTER = \"${model}\"; #"

    wrapProgram $basedir/cupswrapper/brother_lpdwrapper_${model} \
      --prefix PATH ":" ${
        lib.makeBinPath [
          coreutils
          gnugrep
        ]
      }

    substituteInPlace $basedir/lpd/filter_${model} \
      --replace-fail "BR_PRT_PATH =~" "BR_PRT_PATH = \"$basedir\"; #" \
      --replace-fail "PRINTER =~" "PRINTER = \"${model}\"; #"

    wrapProgram $basedir/lpd/filter_${model} \
      --prefix PATH ":" ${
        lib.makeBinPath [
          coreutils
          file
          ghostscript
          gnugrep
          gnused
          which
        ]
      }

    mkdir -p $out/lib/cups/filter
    mkdir -p $out/share/cups/model
    ln -s $basedir/cupswrapper/brother_lpdwrapper_${model} $out/lib/cups/filter
    ln -s $basedir/cupswrapper/brother_${model}_printer_en.ppd $out/share/cups/model

    # bundled scripts don't understand the arch subdirectories for some reason      
    ln -s $basedir/lpd/${stdenv.hostPlatform.linuxArch}/* $basedir/lpd/

    wrapProgram $basedir/lpd/br${model}filter \
      --set LD_PRELOAD "${libredirect}/lib/libredirect.so" \
      --set NIX_REDIRECTS "/opt=$out/opt"

    wrapProgram $basedir/lpd/brprintconf_${model} \
      --set LD_PRELOAD "${libredirect}/lib/libredirect.so" \
      --set NIX_REDIRECTS "/opt=$out/opt"

  '';

  meta = {
    description = "Brother ${lib.strings.toUpper exactModel} CUPS wrapper driver";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = [
      lib.licenses.gpl2Only
      # lib.licenses.unfree
    ];
    maintainers = [
      # lib.maintainers.djacu
    ];
    platforms = [
      "x86_64-linux"
      "i686-linux"
    ];
    homepage = "http://www.brother.com/";
    downloadPage = "https://support.brother.com/g/b/downloadlist.aspx?c=us&lang=en&prod=hll3280cdw_us_as&os=128";
  };

})
