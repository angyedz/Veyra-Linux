// veyra-ota-keygen creates a new offline Ed25519 release signing identity.
// NEVER store the private key in git, CI, images or public artifacts.
package main

import (
    "crypto/ed25519"
    "crypto/rand"
    "crypto/x509"
    "encoding/base64"
    "encoding/pem"
    "errors"
    "flag"
    "fmt"
    "io"
    "os"
    "path/filepath"
)

func main() {
    if err := run(os.Args[1:]); err != nil {
        fmt.Fprintln(os.Stderr, "veyra-ota-keygen:", err)
        os.Exit(1)
    }
}

func run(args []string) error {
    flags := flag.NewFlagSet("veyra-ota-keygen", flag.ContinueOnError)
    flags.SetOutput(io.Discard)
    directory := flags.String("out", "", "absolute path to NEW private key directory")
    if err := flags.Parse(args); err != nil { return err }
    if flags.NArg() != 0 || !filepath.IsAbs(*directory) || filepath.Clean(*directory) == "/" {
        return errors.New("usage: veyra-ota-keygen --out /private/new-directory")
    }
    // Both files must be created exclusively. Private directory is 0700.
    if err := os.Mkdir(*directory,0700); err != nil {
        return fmt.Errorf("refusing to reuse signing-key directory: %w",err)
    }
    public,private,err := ed25519.GenerateKey(rand.Reader)
    if err != nil { return err }
    pkcs8,err := x509.MarshalPKCS8PrivateKey(private)
    if err != nil { return err }
    encodedPrivate := pem.EncodeToMemory(&pem.Block{Type:"PRIVATE KEY",Bytes:pkcs8})
    encodedPublic := []byte(base64.StdEncoding.EncodeToString(public)+"\n")
    for _,item := range []struct {
        name string
        mode os.FileMode
        data []byte
    }{
        {"veyra-update-private.pem",0600,encodedPrivate},
        {"veyra-update-public.pub",0644,encodedPublic},
    } {
        file,err := os.OpenFile(filepath.Join(*directory,item.name),os.O_WRONLY|os.O_CREATE|os.O_EXCL,item.mode)
        if err != nil { return err }
        if _,err = file.Write(item.data); err == nil { err = file.Sync() }
        if closeErr := file.Close(); err == nil { err = closeErr }
        if err != nil { return err }
    }
    fmt.Println("Private signing key created at:",filepath.Join(*directory,"veyra-update-private.pem"))
    fmt.Println("Trusted public key created at:",filepath.Join(*directory,"veyra-update-public.pub"))
    fmt.Println("KEEP THE PRIVATE KEY OFF GITHUB, CI, ISO AND ALL SHARED MACHINES.")
    return nil
}
