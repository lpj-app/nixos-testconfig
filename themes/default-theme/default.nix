# Intro plymouth scripting language: https://www.freedesktop.org/wiki/Software/Plymouth/Scripts/

{ pkgs }:

let
  THEME_NAME = "default-theme";
  THEME_DIR = "$out/share/plymouth/themes/${THEME_NAME}";
in

pkgs.stdenv.mkDerivation {
  name = THEME_NAME;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.imagemagick ];

  installPhase = ''
    mkdir -p ${THEME_DIR}

    cp ${./default-theme.script} ${THEME_DIR}/${THEME_NAME}.script
    cp ${../../assets/themes/lpj.app.png} ${THEME_DIR}/logo.png

    # Spinner graphic: a 3/4 ring, rotated at runtime in the script
    convert -size 32x32 xc:none -strokewidth 3 -stroke white -fill none \
      -draw "arc 3,3 29,29 0,270" ${THEME_DIR}/spinner.png

    cat <<EOF > ${THEME_DIR}/${THEME_NAME}.plymouth
[Plymouth Theme]
Name=${THEME_NAME}
Description=Custom theme with own logo
ModuleName=script

[script]
ImageDir=${THEME_DIR}
ScriptFile=${THEME_DIR}/${THEME_NAME}.script
EOF
  '';
}