# SPDX-FileCopyrightText: © 2026 Yiyu Zhou <yiyu@yiyuzhou.io>
# SPDX-License-Identifier: 0BSD OR CC0-1.0

{
  description = "kewuaa's window manager for River Wayland compositor";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=master";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        reuseLint = pkgs.stdenv.mkDerivation {
          pname = "kwm-reuse-lint";
          version = "0.1.0";
          src = pkgs.lib.cleanSource ./.; # Respect .gitignore
          nativeBuildInputs = [ pkgs.reuse ];
          buildPhase = ''
            reuse lint
          '';
          installPhase = ''
            mkdir -p "$out"
          '';
        };
      in
      {
        packages.reuse-lint = reuseLint;
        checks.default = reuseLint;
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            reuse
          ];
        };
      }
    );
}
