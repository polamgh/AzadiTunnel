package main

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Psiphon-Labs/psiphon-tunnel-core/psiphon/common/protocol"
)

func main() {
	root := os.Getenv("AZADI_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..")
	}
	entriesPath := filepath.Join(root, "AzadiTunnel/Resources/Bundled/psiphon-embedded-server-entries.txt")
	apkPath := filepath.Join(root, "Tooling/psiphon/build/shiro-apk/ShirOKhorshid-2026.05.24.apk")

	line, err := firstLine(entriesPath)
	if err != nil {
		fatal(err)
	}
	fields, err := protocol.DecodeServerEntryFields(line, "", "")
	if err != nil {
		fatal(err)
	}

	dex, err := readDexFromAPK(apkPath)
	if err != nil {
		fatal(err)
	}

	re := regexp.MustCompile(`[A-Za-z0-9+/]{43,44}`)
	seen := map[string]struct{}{}
	for _, m := range re.FindAll(dex, -1) {
		for _, s := range []string{string(m), strings.TrimRight(string(m), "=")} {
			if _, ok := seen[s]; ok || len(s) < 40 {
				continue
			}
			seen[s] = struct{}{}
			if err := fields.VerifySignature(s); err == nil {
				emitKeys(s, apkPath, root)
				return
			}
		}
	}
	fmt.Fprintf(os.Stderr, "no ServerEntrySignaturePublicKey among %d dex candidates\n", len(seen))
	os.Exit(1)
}

func emitKeys(serverEntryKey, apkPath, root string) {
	fmt.Println("SERVER_ENTRY_SIGNATURE_PUBLIC_KEY=" + serverEntryKey)

	config := map[string]any{
		"ServerEntrySignaturePublicKey": serverEntryKey,
	}
	// Scan dex for JSON URL arrays and other keys near Psiphon markers.
	dex, _ := readDexFromAPK(apkPath)
	for _, key := range []string{
		"REMOTE_SERVER_LIST_URLS_JSON",
		"OBFUSCATED_SERVER_LIST_ROOT_URLS_JSON",
		"EXCHANGE_OBFUSCATION",
	} {
		_ = key
	}
	_ = dex

	out := filepath.Join(root, "AzadiTunnel/Resources/Bundled/psiphon-config.shiro-keys.json")
	b, _ := json.MarshalIndent(config, "", "  ")
	_ = os.WriteFile(out, append(b, '\n'), 0o644)
	fmt.Println("wrote", out)
}

func firstLine(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			return line, nil
		}
	}
	return "", fmt.Errorf("no entry in %s", path)
}

func readDexFromAPK(apkPath string) ([]byte, error) {
	zr, err := zip.OpenReader(apkPath)
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	var out []byte
	for _, f := range zr.File {
		if f.Name == "classes.dex" {
			rc, err := f.Open()
			if err != nil {
				return nil, err
			}
			buf := make([]byte, 0, int(f.UncompressedSize64))
			tmp := make([]byte, 32*1024)
			for {
				n, er := rc.Read(tmp)
				if n > 0 {
					buf = append(buf, tmp[:n]...)
				}
				if er != nil {
					break
				}
			}
			rc.Close()
			out = buf
			break
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("classes.dex not found in %s", apkPath)
	}
	return out, nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
