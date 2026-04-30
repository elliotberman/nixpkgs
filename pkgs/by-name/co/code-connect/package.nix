{
  fetchFromGitHub,
  lib,
  makeWrapper,
  python3Packages,
  socat,
  stdenv,
}:
# we don't use buildPythonPackage because the pyproject.toml is for running formatters and doesn't produce any outputs
stdenv.mkDerivation (finalAttrs: {
  pname = "code-connect";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "chvolkmann";
    repo = "code-connect";
    rev = "v${finalAttrs.version}";
    hash = "sha256-rNrvDgqt223cWsEDTeyqXlcIzHcqZHQnQTD7t84SYQ0=";
  };

  doCheck = false;
  dontBuild = true;

  nativeBuildInputs = [
    makeWrapper
    python3Packages.wrapPython
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/code_connect.py $out/bin/code

    wrapProgram $out/bin/code \
      --prefix PATH : "${lib.makeBinPath [ socat ]}"

    wrapPythonPrograms

    runHook postInstall
  '';

  meta = {
    description = "Open a file in your locally running Visual Studio Code instance from arbitrary terminal connections.";
    longDescription = ''
      VS Code supports opening files with the terminal using code /path/to/file. While this is possible in WSL sessions and remote SSH sessions if the integrated terminal is used, it is currently not possible for arbitrary terminal sessions, e.g. Windows Terminal or kitty.

      Let's say you have just SSH'd into a remote server using your favorite terminal and would like to view a webserver config in your local VS Code instance. So you type code nginx.conf, which doesn't work in this terminal. If you try to run code nginx.conf in the integrated terminal however, VS Code opens the file just fine.

      The aim of this project is to make the code CLI available to any terminal, not only to VS Code's integrated terminal.
    '';
    homepage = "https://github.com/chvolkmann/code-connect";
    mainProgram = "code";
    license = lib.licenses.mit;
    maintainers = [
      lib.maintainers.elliotberman
    ];
  };
})
