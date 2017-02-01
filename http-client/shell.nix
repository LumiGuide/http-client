{ nixpkgs ? import <nixpkgs> {}, compiler ? "default" }:

let

  inherit (nixpkgs) pkgs;

  f = { mkDerivation, array, async, base, base64-bytestring
      , blaze-builder, bytestring, case-insensitive, containers, cookie
      , deepseq, directory, exceptions, filepath, ghc-prim, hspec
      , http-types, mime-types, monad-control, network, network-uri
      , random, stdenv, streaming-commons, text, time, transformers, zlib
      }:
      mkDerivation {
        pname = "http-client";
        version = "0.5.5";
        src = ./.;
        libraryHaskellDepends = [
          array base base64-bytestring blaze-builder bytestring
          case-insensitive containers cookie deepseq exceptions filepath
          ghc-prim http-types mime-types network network-uri random
          streaming-commons text time transformers
        ];
        testHaskellDepends = [
          async base base64-bytestring blaze-builder bytestring
          case-insensitive containers deepseq directory hspec http-types
          monad-control network network-uri streaming-commons text time
          transformers zlib
        ];
        doCheck = false;
        homepage = "https://github.com/snoyberg/http-client";
        description = "An HTTP client engine";
        license = stdenv.lib.licenses.mit;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  drv = haskellPackages.callPackage f {};

in

  if pkgs.lib.inNixShell then drv.env else drv
