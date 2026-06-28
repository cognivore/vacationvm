# Nix package for the vacationvm-dns reconciler.
#
# Zero runtime dependencies (standard library only), so this is a trivial
# buildPythonApplication — no propagatedBuildInputs, no lockfile. The test
# suite (also stdlib-only) runs in the check phase so a broken reconciler
# fails the build rather than your DNS.
{
  lib,
  python3,
}:

python3.pkgs.buildPythonApplication {
  pname = "vacationvm-dns";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3.pkgs.setuptools ];

  # Run the unittest suite as the package check.
  nativeCheckInputs = [ ];
  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} -m unittest discover -s tests -v
    runHook postCheck
  '';

  pythonImportsCheck = [ "vacationvm_dns" ];

  meta = {
    description = "Stateless declarative Porkbun DNS reconciler for vacationvm";
    mainProgram = "vacationvm-dns";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.unix;
  };
}
