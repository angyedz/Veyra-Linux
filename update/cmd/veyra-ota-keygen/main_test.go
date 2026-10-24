package main

import (
    "crypto/ed25519"
    "crypto/x509"
    "encoding/base64"
    "encoding/pem"
    "os"
    "path/filepath"
    "testing"
)

func TestNewKeysProtectedAndMatching(t *testing.T) {
    dir := filepath.Join(t.TempDir(),"keys")
    if err := run([]string{"--out",dir}); err != nil { t.Fatal(err) }
    info,err := os.Stat(dir)
    if err != nil { t.Fatal(err) }
    if info.Mode().Perm() != 0700 { t.Fatalf("directory permissions: %o",info.Mode().Perm()) }
    secretPath := filepath.Join(dir,"veyra-update-private.pem")
    pubPath := filepath.Join(dir,"veyra-update-public.pub")
    secretInfo,err := os.Stat(secretPath)
    if err != nil { t.Fatal(err) }
    if secretInfo.Mode().Perm() != 0600 { t.Fatalf("private key permissions: %o",secretInfo.Mode().Perm()) }
    data,err := os.ReadFile(secretPath)
    if err != nil { t.Fatal(err) }
    block,rest := pem.Decode(data)
    if block == nil || len(rest) != 0 || block.Type != "PRIVATE KEY" { t.Fatal("invalid private PEM") }
    parsed,err := x509.ParsePKCS8PrivateKey(block.Bytes)
    if err != nil { t.Fatal(err) }
    private,ok := parsed.(ed25519.PrivateKey)
    if !ok { t.Fatal("not Ed25519 private key") }
    encoded,err := os.ReadFile(pubPath)
    if err != nil { t.Fatal(err) }
    public,err := base64.StdEncoding.DecodeString(string(encoded[:len(encoded)-1]))
    if err != nil { t.Fatal(err) }
    message := []byte("Veyra release signature fixture")
    signature := ed25519.Sign(private,message)
    if !ed25519.Verify(public,message,signature) { t.Fatal("generated public key mismatched private") }
    if err := run([]string{"--out",dir}); err == nil { t.Fatal("must not reuse key directory") }
    if err := run([]string{"--out","relative-path"}); err == nil { t.Fatal("must reject relative output") }
}
