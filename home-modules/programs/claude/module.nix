{
  config,
  lib,
  pkgs,
  ...
}:
let

  inherit (lib.options)
    mkEnableOption
    ;

  inherit (lib.modules)
    mkIf
    ;

  cfg = config.theonecfg.programs.claude;

in
{

  options.theonecfg.programs.claude.enable = mkEnableOption "claude package config";

  config = mkIf cfg.enable {

    nixpkgs.config.allowUnfree = true;

    programs.claude-code = {

      enable = true;

      context = ''
        # Working principles

        ## Investigation
        - Don't act on unverified inference about how a system or its dependencies behave. Validate via source code, documentation, or testing. State explicitly when operating on inference and what would invalidate the assumption.
        - When investigating, iterate until a pass discovers nothing new. Before acting, explicitly list any remaining assumptions and the risk if each is wrong.
        - Distinguish "code compiled / typechecked" from "feature works." Be explicit about what was actually exercised end-to-end vs. only statically validated.

        ## Asking and deciding
        - Ask the user when (a) the answer would materially change the approach, (b) the action is hard to reverse, or (c) more than one reasonable interpretation of intent exists. For low-stakes ambiguity, pick a default, state it explicitly, and proceed.
        - When picking a default in an ambiguous case, name the choice and the alternative rejected in one line.

        ## Implementation discipline
        - Don't refactor, rename, or clean up adjacent code unless explicitly asked. A bug fix doesn't need surrounding improvements.
        - No speculative abstractions. Don't extract helpers, add config options, or design for hypothetical futures. Three similar lines beats a premature abstraction.
        - No defensive code at internal boundaries. Don't add validation or fallbacks for cases that can't happen. Trust internal callers; only validate at system boundaries.

        ## Verification after changes
        - After every edit, read the final file region to confirm the result matches intent. This catches Edit applying to the wrong location.
        - Run the project's own checks (lint, typecheck, tests, build) before declaring done. Don't claim success on the basis of "the edit applied cleanly."

        ## Sub-agents
        - Don't trust a sub-agent's report. Verify the artifact directly: read the file the agent claims to have edited; re-run the command the agent claims passed. Flag vague claims and unstated uncertainty.
        - Brief sub-agents on constraints, not just goals. Tell them what NOT to do (don't expand scope, don't add comments, don't create helpers) — they don't inherit these rules.

        ## Reporting
        - End each task with: what changed / what's still open / what was not verified. No padding.
      '';

      mcpServers.nixos = {
        type = "stdio";
        command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
      };

      lspServers = {
        nix = {
          command = "${pkgs.nixd}/bin/nixd";
          extensionToLanguage = {
            ".nix" = "nix";
          };
        };
        rust = {
          command = "${pkgs.rust-analyzer}/bin/rust-analyzer";
          extensionToLanguage = {
            ".rs" = "rust";
          };
        };
        cpp = {
          command = "${pkgs.clang-tools}/bin/clangd";
          extensionToLanguage = {
            ".c" = "c";
            ".h" = "c";
            ".cc" = "cpp";
            ".cpp" = "cpp";
            ".cxx" = "cpp";
            ".hh" = "cpp";
            ".hpp" = "cpp";
          };
        };
        go = {
          command = "${pkgs.gopls}/bin/gopls";
          args = [ "serve" ];
          extensionToLanguage = {
            ".go" = "go";
          };
        };
        typescript = {
          command = "${pkgs.vtsls}/bin/vtsls";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".ts" = "typescript";
            ".tsx" = "typescriptreact";
            ".js" = "javascript";
            ".jsx" = "javascriptreact";
          };
        };
        tailwind = {
          command = "${pkgs.tailwindcss-language-server}/bin/tailwindcss-language-server";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".html" = "html";
            ".tsx" = "typescriptreact";
            ".jsx" = "javascriptreact";
          };
        };
        python = {
          command = "${pkgs.basedpyright}/bin/basedpyright-langserver";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".py" = "python";
            ".pyi" = "python";
          };
        };
        java = {
          command = "${pkgs.jdt-language-server}/bin/jdtls";
          extensionToLanguage = {
            ".java" = "java";
          };
        };
        bash = {
          command = "${pkgs.bash-language-server}/bin/bash-language-server";
          args = [ "start" ];
          extensionToLanguage = {
            ".sh" = "shellscript";
            ".bash" = "shellscript";
          };
        };
        yaml = {
          command = "${pkgs.yaml-language-server}/bin/yaml-language-server";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".yml" = "yaml";
            ".yaml" = "yaml";
          };
        };
        html = {
          command = "${pkgs.vscode-langservers-extracted}/bin/vscode-html-language-server";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".html" = "html";
            ".htm" = "html";
          };
        };
        css = {
          command = "${pkgs.vscode-langservers-extracted}/bin/vscode-css-language-server";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".css" = "css";
            ".scss" = "scss";
            ".less" = "less";
          };
        };
        json = {
          command = "${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server";
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".json" = "json";
            ".jsonc" = "jsonc";
          };
        };
        toml = {
          command = "${pkgs.taplo}/bin/taplo";
          args = [
            "lsp"
            "stdio"
          ];
          extensionToLanguage = {
            ".toml" = "toml";
          };
        };
        markdown = {
          command = "${pkgs.marksman}/bin/marksman";
          args = [ "server" ];
          extensionToLanguage = {
            ".md" = "markdown";
            ".markdown" = "markdown";
          };
        };
      };
    };

  };

}
