// Fetches the signed common remote server list (same as tunnel-core on first connect)
// and writes unique server entry lines for bootstrap supplement.
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/Psiphon-Labs/psiphon-tunnel-core/psiphon"
	"github.com/Psiphon-Labs/psiphon-tunnel-core/psiphon/common/errors"
	"github.com/Psiphon-Labs/psiphon-tunnel-core/psiphon/common/protocol"
	utls "github.com/Psiphon-Labs/utls"
)

func main() {
	configPath := flag.String("config", "", "merged psiphon-config JSON (bundled+local)")
	dataDir := flag.String("data-dir", "", "temp datastore directory")
	outPath := flag.String("out", "", "output .txt (one entry line per line)")
	embeddedPath := flag.String("embedded", "", "optional existing embedded entries to skip duplicates")
	flag.Parse()

	if *configPath == "" || *dataDir == "" || *outPath == "" {
		fmt.Fprintln(os.Stderr, "usage: fetch-remote-entries -config merged.json -data-dir DIR -out supplement.txt [-embedded entries.txt]")
		os.Exit(2)
	}

	configJSON, err := os.ReadFile(*configPath)
	if err != nil {
		fatal(err)
	}

	config, err := psiphon.LoadConfig(configJSON)
	if err != nil {
		fatal(err)
	}
	config.DataStoreDirectory = *dataDir
	if err := os.MkdirAll(*dataDir, 0o700); err != nil {
		fatal(err)
	}
	if err := config.Commit(true); err != nil {
		fatal(err)
	}

	existing := map[string]struct{}{}
	if *embeddedPath != "" {
		loadExistingLines(*embeddedPath, existing)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	if err := psiphon.OpenDataStore(config); err != nil {
		fatal(err)
	}
	defer psiphon.CloseDataStore()

	untunneledDialConfig := &psiphon.DialConfig{
		ResolveIP: func(ctx context.Context, hostname string) ([]net.IP, error) {
			return psiphon.UntunneledResolveIP(ctx, config, nil, hostname, "")
		},
		UpstreamProxyURL: config.UpstreamProxyURL,
	}
	tlsCache := utls.NewLRUClientSessionCache(0)

	if err := psiphon.FetchCommonRemoteServerList(ctx, config, 0, nil, untunneledDialConfig, tlsCache); err != nil {
		fatal(err)
	}

	var lines []string
	err = psiphon.ScanServerEntries(func(entry *protocol.ServerEntry) bool {
		encoded, err := protocol.EncodeServerEntry(entry)
		if err != nil {
			return true
		}
		if _, ok := existing[encoded]; ok {
			return true
		}
		existing[encoded] = struct{}{}
		lines = append(lines, encoded)
		return true
	})
	if err != nil {
		fatal(err)
	}
	if len(lines) == 0 {
		fmt.Fprintln(os.Stderr, "no new server entries after fetch")
		os.Exit(1)
	}

	out := ""
	for i, line := range lines {
		if i > 0 {
			out += "\n"
		}
		out += line
	}
	if err := os.WriteFile(*outPath, []byte(out+"\n"), 0o600); err != nil {
		fatal(err)
	}
	fmt.Printf("wrote %s (%d new lines, datastore=%s)\n", *outPath, len(lines), *dataDir)
}

func loadExistingLines(path string, seen map[string]struct{}) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	for _, line := range splitLines(string(b)) {
		seen[line] = struct{}{}
	}
}

func splitLines(text string) []string {
	var out []string
	start := 0
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' {
			line := trimLine(text[start:i])
			if line != "" {
				out = append(out, line)
			}
			start = i + 1
		}
	}
	if start < len(text) {
		if line := trimLine(text[start:]); line != "" {
			out = append(out, line)
		}
	}
	return out
}

func trimLine(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t' || s[0] == '\r') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t' || s[len(s)-1] == '\r') {
		s = s[len(s)-1:]
	}
	if len(s) > 0 && s[0] == '#' {
		return ""
	}
	return s
}

func fatal(err error) {
	var msg string
	if err != nil {
		msg = errors.Trace(err).Error()
	}
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
