// veyra-ota-bundle signs a paired APK release manifest and binds it to an
// installer ISO for publication. An ISO is NOT an A/B update payload.
// Run on a trusted maintainer machine; never upload the private key.
package main

import (
    "crypto/ed25519"
    "crypto/sha256"
    "crypto/sha512"
    "crypto/x509"
    "encoding/base64"
    "encoding/hex"
    "encoding/json"
    "encoding/pem"
    "errors"
    "flag"
    "fmt"
    "io"
    "os"
    "path/filepath"
    "strings"

    update "veyra-update"
)

type releaseInfo struct {
    Format string `json:"format"`
    Release string `json:"release"`
    Sequence uint64 `json:"sequence"`
    Architecture string `json:"architecture"`
    ISO string `json:"iso"`
    SHA256 string `json:"sha256"`
    SHA512 string `json:"sha512"`
    OTAContract string `json:"ota_contract"`
}

func main() {
    if err := run(os.Args[1:]); err != nil {
        fmt.Fprintln(os.Stderr, "veyra-ota-bundle:", err)
        os.Exit(1)
    }
}

func run(args []string) error {
    flags := flag.NewFlagSet("veyra-ota-bundle", flag.ContinueOnError)
    flags.SetOutput(io.Discard)
    iso := flags.String("iso", "", "immutable installation ISO")
    manifest := flags.String("manifest", "", "paired APK release JSON")
    signingKey := flags.String("signing-key", "", "offline Ed25519 PKCS#8 PEM private key")
    trustedKey := flags.String("public-key", "", "public key trusted by installed Veyra")
    output := flags.String("out", "", "new output bundle directory")
    if err := flags.Parse(args); err != nil { return err }
    if flags.NArg() != 0 || *iso == "" || *manifest == "" ||
        *signingKey == "" || *trustedKey == "" || *output == "" {
        return errors.New("usage: veyra-ota-bundle --iso IMAGE.iso --manifest release.json --signing-key PRIVATE.pem --public-key TRUSTED.pub --out NEW_DIRECTORY")
    }
    if strings.ContainsAny(filepath.Base(*iso), "\n\r") ||
        !strings.HasSuffix(strings.ToLower(filepath.Base(*iso)), ".iso") {
        return errors.New("ISO must have a safe .iso filename")
    }
    doc, err := readRegular(*manifest, 1<<20)
    if err != nil { return fmt.Errorf("release manifest: %w", err) }
    keyBytes, err := readRegular(*signingKey, 4096)
    if err != nil { return fmt.Errorf("private key: %w", err) }
    keyInfo, err := os.Stat(*signingKey)
    if err != nil { return err }
    if keyInfo.Mode().Perm() & 0077 != 0 {
        return errors.New("private signing key must not be readable or writable by group/others (chmod 600)")
    }
    block, rest := pem.Decode(keyBytes)
    if block == nil || block.Type != "PRIVATE KEY" || len(strings.TrimSpace(string(rest))) != 0 {
        return errors.New("expected a single PKCS#8 PEM PRIVATE KEY")
    }
    parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
    if err != nil { return fmt.Errorf("parse Ed25519 PKCS#8 key: %w", err) }
    priv, ok := parsed.(ed25519.PrivateKey)
    if !ok { return errors.New("only Ed25519 signing keys are supported") }
    publicKeyBytes, err := readRegular(*trustedKey, 256)
    if err != nil { return fmt.Errorf("trusted public key: %w", err) }
    sig := []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(priv, doc)) + "\n")
    verified, err := update.VerifyRelease(doc, sig, publicKeyBytes)
    if err != nil {
        return fmt.Errorf("signature, trusted key or release contract is invalid: %w", err)
    }
    isoFile, err := openRegular(*iso)
    if err != nil { return fmt.Errorf("installer ISO: %w", err) }
    defer isoFile.Close()
    hasher256, hasher512 := sha256.New(), sha512.New()
    if _, err := io.Copy(io.MultiWriter(hasher256, hasher512), isoFile); err != nil {
        return fmt.Errorf("hash installer ISO: %w", err)
    }
    digest256, digest512 := hex.EncodeToString(hasher256.Sum(nil)), hex.EncodeToString(hasher512.Sum(nil))
    release := verified.Manifest()
    info, err := json.MarshalIndent(releaseInfo{
        Format:"veyra-ota-bundle-v1", Release:release.Release, Sequence:release.Sequence,
        Architecture:release.Architecture, ISO:filepath.Base(*iso),
        SHA256:digest256, SHA512:digest512,
        OTAContract:"signed-paired-apk-generations; ISO-is-installer-only",
    }, "", "  ")
    if err != nil { return err }
    if !filepath.IsAbs(*output) { return errors.New("--out must be an absolute path") }
    if _, err := os.Lstat(*output); err == nil {
        return errors.New("output already exists; refusing to overwrite a previous release")
    } else if !errors.Is(err, os.ErrNotExist) { return err }
    parent := filepath.Dir(*output)
    temporary, err := os.MkdirTemp(parent, ".veyra-ota-staging-")
    if err != nil { return err }
    defer os.RemoveAll(temporary)
    files := map[string][]byte{
        "manifest.json":doc,
        "manifest.json.sig":sig,
        "release-info.json":append(info, '\n'),
        "iso.sha256":[]byte(digest256+"  "+filepath.Base(*iso)+"\n"),
        "iso.sha512":[]byte(digest512+"  "+filepath.Base(*iso)+"\n"),
        "README.txt":[]byte("VEYRA OTA RELEASE BUNDLE\n\nAttach the ISO separately for fresh installs.\nPublish manifest.json and manifest.json.sig unchanged at the configured HTTPS channel URL.\nThe signed manifest selects repository APKs for inactive system/user generations.\nDo not flash the ISO onto an installed filesystem.\nNever publish private signing keys.\nThis bundle is NOT a Pre-Alpha qualification result.\n"),
    }
    for name, content := range files {
        if err := writeSynced(filepath.Join(temporary, name), content); err != nil { return err }
    }
    if err := syncDir(temporary); err != nil { return err }
    // Refuse a concurrent output creator instead of replacing its contents.
    if _, err := os.Lstat(*output); err == nil {
        return errors.New("output appeared while staging; refusing to overwrite")
    } else if !errors.Is(err, os.ErrNotExist) { return err }
    if err := os.Rename(temporary, *output); err != nil { return err }
    if err := syncDir(parent); err != nil { return err }
    fmt.Printf("Signed OTA metadata for %s (sequence %d): %s\n", release.Release, release.Sequence, *output)
    fmt.Println("The ISO is a separate installer artifact; OTA stages signed APK generations.")
    return nil
}

func openRegular(path string) (*os.File, error) {
    info, err := os.Lstat(path)
    if err != nil { return nil, err }
    if !info.Mode().IsRegular() { return nil, errors.New("expected non-symlink regular file") }
    file, err := os.Open(path)
    if err != nil { return nil, err }
    opened, err := file.Stat()
    if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
        file.Close()
        return nil, errors.New("input changed or was not a regular file")
    }
    if opened.Size() == 0 {
        file.Close()
        return nil, errors.New("empty input file")
    }
    return file, nil
}

func readRegular(path string, limit int64) ([]byte, error) {
    f, err := openRegular(path)
    if err != nil { return nil, err }
    defer f.Close()
    info, err := f.Stat()
    if err != nil { return nil, err }
    if info.Size() > limit { return nil, errors.New("input exceeds maximum size") }
    b, err := io.ReadAll(io.LimitReader(f, limit+1))
    if err != nil { return nil, err }
    if int64(len(b)) > limit { return nil, errors.New("input exceeds maximum size") }
    return b, nil
}

func writeSynced(path string, data []byte) error {
    f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
    if err != nil { return err }
    if _, err = f.Write(data); err == nil { err = f.Sync() }
    if e := f.Close(); err == nil { err = e }
    return err
}

func syncDir(path string) error {
    f, err := os.Open(path)
    if err != nil { return err }
    defer f.Close()
    return f.Sync()
}
