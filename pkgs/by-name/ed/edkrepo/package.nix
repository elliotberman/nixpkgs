{
  fetchFromGitHub,
  gitMinimal,
  lib,
  nix-update-script,
  stdenv,
  python3Packages,
}:

python3Packages.buildPythonApplication (finalAttrs: {
  pname = "edkrepo";
  version = "3.4.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "tianocore";
    repo = "edk2-edkrepo";
    tag = "edkrepo-v${finalAttrs.version}";
    hash = "sha256-tNOag5Lr2lLUlKcCMpsnX/eaV4dT6q5yidiOTZ7QR/Q=";
  };

  build-system = [ python3Packages.setuptools ];

  dependencies = with python3Packages; [
    gitpython
    colorama
    setuptools # pkg_resources used at runtime by edkrepo/edkrepo_cli.py
  ];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ gitMinimal ])
  ];

  nativeCheckInputs = with python3Packages; [ pytestCheckHook ];
  pythonImportsCheck = [
    "edkrepo"
    "edkrepo_manifest_parser"
    "project_utils"
  ];
  disabledTests = lib.optionals (!stdenv.hostPlatform.isWindows) [
    # Test only works on Windows
    "test_generate_exclude_pattern_different_drives"
  ];

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--version-regex"
      "edkrepo-v([0-9.]+)"
    ];
  };

  meta = {
    description = "Multi-repository tool for EDK II firmware development,";
    homepage = "https://github.com/tianocore/edk2-edkrepo";
    license = lib.licenses.bsd2Patent;
    maintainers = with lib.maintainers; [ elliotberman ];
    mainProgram = "edkrepo";
  };
})
