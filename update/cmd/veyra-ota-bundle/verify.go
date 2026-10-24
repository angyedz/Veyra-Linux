package main

import (
    "bytes"
    "crypto/ed25519"
    "crypto/sha256"
    "crypto/sha512"
    "encoding/base64"
    "encoding/hex"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "os"
    "path/filepath"
    "strings"

    update "veyra-update"
)

// verifyBundle independently validates every artifact needed to publish an
// immutable ISO and a signed pair of APK-generation manifests. It never reads
// the private signing key and does not modify a deployment.
func verifyBundle(bundle, iso, publicKeyPath string) error {
    dir,err := os.Lstat(bundle)
    if err != nil { return err }
    if !dir.IsDir() { return errors.New("bundle must be a real non-symlink directory") }
    keyData,err := readRegular(publicKeyPath,256)
    if err != nil { return fmt.Errorf("trusted public key: %w",err) }
    var trusted []byte
    if len(keyData) == ed25519.PublicKeySize {
        trusted = keyData
    } else {
        trusted,err = base64.StdEncoding.DecodeString(strings.TrimSpace(string(keyData)))
        if err != nil || len(trusted) != ed25519.PublicKeySize {
            return errors.New("trusted public key must be raw Ed25519 or base64")
        }
    }
    doc,err := readRegular(filepath.Join(bundle,"manifest.json"),1<<20)
    if err != nil { return fmt.Errorf("manifest: %w",err) }
    sig,err := readRegular(filepath.Join(bundle,"manifest.json.sig"),256)
    if err != nil { return fmt.Errorf("manifest signature: %w",err) }
    verified,err := update.VerifyRelease(doc,sig,keyData)
    if err != nil { return fmt.Errorf("signed paired release: %w",err) }
    infoBytes,err := readRegular(filepath.Join(bundle,"release-info.json"),4096)
    if err != nil { return fmt.Errorf("release metadata: %w",err) }
    infoSig,err := readRegular(filepath.Join(bundle,"release-info.json.sig"),256)
    if err != nil { return fmt.Errorf("release metadata signature: %w",err) }
    decodedSig,err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(infoSig)))
    if err != nil || len(decodedSig) != ed25519.SignatureSize ||
        !ed25519.Verify(trusted,infoBytes,decodedSig) {
        return errors.New("ISO release metadata signature is invalid")
    }
    decoder := json.NewDecoder(bytes.NewReader(infoBytes))
    decoder.DisallowUnknownFields()
    var info releaseInfo
    if err := decoder.Decode(&info); err != nil { return fmt.Errorf("invalid ISO release metadata: %w",err) }
    if err := decoder.Decode(new(any)); !errors.Is(err,io.EOF) {
        return errors.New("ISO release metadata has trailing JSON")
    }
    manifest := verified.Manifest()
    if info.Format != "veyra-ota-bundle-v1" ||
        info.Release != manifest.Release ||
        info.Sequence != manifest.Sequence ||
        info.Architecture != manifest.Architecture ||
        info.OTAContract != "signed-paired-apk-generations; ISO-is-installer-only" ||
        info.ISO != filepath.Base(iso) {
        return errors.New("ISO metadata does not match the authenticated paired-release contract")
    }
    if filepath.Base(iso) == "." || !strings.HasSuffix(strings.ToLower(info.ISO),".iso") {
        return errors.New("invalid ISO filename")
    }
    image,err := openRegular(iso)
    if err != nil { return fmt.Errorf("installer ISO: %w",err) }
    defer image.Close()
    h256,h512 := sha256.New(),sha512.New()
    if _,err := io.Copy(io.MultiWriter(h256,h512),image); err != nil { return err }
    digest256,digest512 := hex.EncodeToString(h256.Sum(nil)),hex.EncodeToString(h512.Sum(nil))
    if !strings.EqualFold(info.SHA256,digest256) || !strings.EqualFold(info.SHA512,digest512) {
        return errors.New("installer ISO hash does not match signed release metadata")
    }
    expected := map[string]string{
        "iso.sha256":digest256+"  "+info.ISO+"\n",
        "iso.sha512":digest512+"  "+info.ISO+"\n",
    }
    for name,value := range expected {
        stored,err := readRegular(filepath.Join(bundle,name),512)
        if err != nil { return fmt.Errorf("%s: %w",name,err) }
        if string(stored) != value { return fmt.Errorf("%s disagrees with signed release metadata",name) }
    }
    fmt.Printf("VERIFIED signed Veyra %s sequence %d with authenticated ISO SHA-256/SHA-512\n",manifest.Release,manifest.Sequence)
    return nil
}
