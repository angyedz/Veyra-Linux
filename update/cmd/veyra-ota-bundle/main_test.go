package main

import (
    "crypto/ed25519"
    "crypto/rand"
    "crypto/sha256"
    "crypto/x509"
    "encoding/base64"
    "encoding/hex"
    "encoding/json"
    "encoding/pem"
    "os"
    "path/filepath"
    "testing"

    update "veyra-update"
)

func sampleInputs(t *testing.T) (string, string, string, string, string) {
    t.Helper()
    dir := t.TempDir()
    iso := filepath.Join(dir, "veyra-pre-alpha.iso")
    if err := os.WriteFile(iso, []byte("DISPOSABLE FAKE ISO - NOT A RELEASE"), 0600); err != nil { t.Fatal(err) }
    manifest := update.Manifest{
        Format:update.ManifestFormat, Release:"pre-alpha-test-1", Sequence:1, Architecture:update.Architecture,
        System:update.Environment{
            ID:"S-test-1", Provides:"system-v1", RequiresOther:"user-v1",
            Repositories:[]update.Repository{{URL:"https://example.org/system"}},
            World:[]string{"alpine-base"}, RequiredPackages:map[string]string{"alpine-base":"3.22.0-r1"},
        },
        User:update.Environment{
            ID:"U-test-1", Provides:"user-v1", RequiresOther:"system-v1",
            Repositories:[]update.Repository{{URL:"https://example.org/user",Tag:"veyra"}},
            World:[]string{"alpine-base"}, RequiredPackages:map[string]string{"alpine-base":"3.22.0-r1"},
        },
    }
    doc, err := json.Marshal(manifest)
    if err != nil { t.Fatal(err) }
    manifestPath := filepath.Join(dir, "release.json")
    if err := os.WriteFile(manifestPath, doc, 0600); err != nil { t.Fatal(err) }
    pub, priv, err := ed25519.GenerateKey(rand.Reader)
    if err != nil { t.Fatal(err) }
    der, err := x509.MarshalPKCS8PrivateKey(priv)
    if err != nil { t.Fatal(err) }
    keyPath := filepath.Join(dir, "private.pem")
    if err := os.WriteFile(keyPath,pem.EncodeToMemory(&pem.Block{Type:"PRIVATE KEY",Bytes:der}),0600); err != nil { t.Fatal(err) }
    pubPath := filepath.Join(dir, "public.pub")
    if err := os.WriteFile(pubPath, []byte(base64.StdEncoding.EncodeToString(pub)+"\n"),0644); err != nil { t.Fatal(err) }
    return iso,manifestPath,keyPath,pubPath,filepath.Join(dir,"bundle")
}

func bundleArgs(iso,manifest,key,pub,out string) []string {
    return []string{"--iso",iso,"--manifest",manifest,"--signing-key",key,"--public-key",pub,"--out",out}
}

func TestSignedBundleAndNoOverwrite(t *testing.T) {
    iso,manifest,key,pub,out := sampleInputs(t)
    if err := run(bundleArgs(iso,manifest,key,pub,out)); err != nil { t.Fatal(err) }
    doc,err := os.ReadFile(filepath.Join(out,"manifest.json"))
    if err != nil { t.Fatal(err) }
    sig,err := os.ReadFile(filepath.Join(out,"manifest.json.sig"))
    if err != nil { t.Fatal(err) }
    pubBytes,err := os.ReadFile(pub)
    if err != nil { t.Fatal(err) }
    if _,err := update.VerifyRelease(doc,sig,pubBytes); err != nil { t.Fatal(err) }
    infoBytes,err := os.ReadFile(filepath.Join(out,"release-info.json"))
    if err != nil { t.Fatal(err) }
    var info releaseInfo
    if err := json.Unmarshal(infoBytes,&info); err != nil { t.Fatal(err) }
    image,err := os.ReadFile(iso)
    if err != nil { t.Fatal(err) }
    sha := sha256.Sum256(image)
    if info.SHA256 != hex.EncodeToString(sha[:]) || info.ISO != filepath.Base(iso) ||
       info.Release != "pre-alpha-test-1" || info.Sequence != 1 {
        t.Fatalf("release information mismatch: %+v",info)
    }
    if _,err := os.Stat(filepath.Join(out,"private.pem")); !os.IsNotExist(err) {
        t.Fatal("the signing key must never be packaged")
    }
    if err := run(bundleArgs(iso,manifest,key,pub,out)); err == nil {
        t.Fatal("must refuse to overwrite an existing signed release")
    }
}

func TestFailClosedOnInvalidInputs(t *testing.T) {
    t.Run("wrong trusted key",func(t *testing.T) {
        iso,manifest,key,pub,out := sampleInputs(t)
        wrong,_,err := ed25519.GenerateKey(rand.Reader)
        if err != nil { t.Fatal(err) }
        if err := os.WriteFile(pub,[]byte(base64.StdEncoding.EncodeToString(wrong)+"\n"),0644); err != nil { t.Fatal(err) }
        if err := run(bundleArgs(iso,manifest,key,pub,out)); err == nil { t.Fatal("must reject mismatched trusted key") }
    })
    t.Run("world changed without resigning",func(t *testing.T) {
        iso,manifest,key,pub,out := sampleInputs(t)
        raw,err := os.ReadFile(manifest)
        if err != nil { t.Fatal(err) }
        if err := os.WriteFile(manifest,append(raw,[]byte("{}")...),0600); err != nil { t.Fatal(err) }
        if err := run(bundleArgs(iso,manifest,key,pub,out)); err == nil { t.Fatal("must reject invalid manifest") }
    })
    t.Run("insecure key permissions",func(t *testing.T) {
        iso,manifest,key,pub,out := sampleInputs(t)
        if err := os.Chmod(key,0644); err != nil { t.Fatal(err) }
        if err := run(bundleArgs(iso,manifest,key,pub,out)); err == nil { t.Fatal("must reject world-readable private key") }
    })
    t.Run("symlinked ISO",func(t *testing.T) {
        iso,manifest,key,pub,out := sampleInputs(t)
        link := filepath.Join(filepath.Dir(iso),"linked.iso")
        if err := os.Symlink(iso,link); err != nil { t.Fatal(err) }
        if err := run(bundleArgs(link,manifest,key,pub,out)); err == nil { t.Fatal("must reject symlinked ISO") }
    })
    t.Run("malformed release",func(t *testing.T) {
        iso,manifest,key,pub,out := sampleInputs(t)
        if err := os.WriteFile(manifest,[]byte("not JSON"),0600); err != nil { t.Fatal(err) }
        if err := run(bundleArgs(iso,manifest,key,pub,out)); err == nil { t.Fatal("must reject malformed release") }
    })
}