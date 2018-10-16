{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  # I like to define variables for derivations that have
  # a specific version and are subject to change over time.
  elixir = beam.packages.erlangR21.elixir_1_7;
  libsecp256k1 = secp256k1.secp256k1-2017-12-18;
  contractbuilding = python-packages: with python-packages; [
    requests
    py-solc
    py-solc-simple
  ];
  pythonForContracts = python3.withPackages contractbuilding;
in

mkShell {
  propagatedBuildInputs = [ elixir git erlangR21 gmp secp256k1 solc pythonForContracts ];
}
