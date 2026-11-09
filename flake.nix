{
  description = "Zig progress";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # GoReleaser 2.19+ maps Zig x86 builds to the 386 package architecture.
    nixpkgs-goreleaser.url = "github:NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-goreleaser,
      git-hooks,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      checks = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files = {
                enable = true;
                excludes = [ "^demo\\.gif$" ];
              };
              check-case-conflicts.enable = true;
              check-merge-conflicts.enable = true;
              commitizen.enable = true;
              deadnix.enable = true;
              end-of-file-fixer.enable = true;
              markdownlint.enable = true;
              nixfmt.enable = true;
              statix.enable = true;
              trim-trailing-whitespace.enable = true;
              typos.enable = true;
              just-fmt = {
                enable = true;
                name = "Justfile format";
                entry = "${pkgs.just}/bin/just --fmt --check";
                files = "^justfile$";
                pass_filenames = false;
              };
              zig-fmt = {
                enable = true;
                name = "Zig format";
                entry = "${pkgs.zig_0_17}/bin/zig fmt --check";
                files = "\\.zig$";
              };
            };
          };
        }
      );

      devShells = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hook = self.checks.${system}.pre-commit-check;
        in
        {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                zig_0_17
                python3
                just
                nixfmt

                gnupg
                nixpkgs-goreleaser.legacyPackages.${system}.goreleaser
                (vhs.override {
                  chromium = chromium.override {
                    commandLineArgs = "--password-store=basic";
                  };
                })
              ]
              ++ hook.enabledPackages;
            inherit (hook) shellHook;
          };
        }
      );
    };
}
