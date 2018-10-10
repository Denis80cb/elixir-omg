{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let
  # I like to define variables for derivations that have
  # a specific version and are subject to change over time.
  elixir = beam.packages.erlangR21.elixir_1_7;
in

mkShell {
  buildInputs = [ elixir git ];
}
