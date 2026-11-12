package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const maxBodyBytes = 8192

type config struct {
	Addr            string
	PiWebURL        *url.URL
	ProjectsFile    string
	ProjectsDir     string
	CredentialsFile string
}

type app struct {
	cfg         config
	projects    *projectStore
	validatePAT func(string) (string, error)
	cloneRepo   func(context.Context, string, string, string) error
	csrfToken   string
}

func loadConfig() (config, error) {
	piWebURL, err := url.Parse(envOr("PLIIK_PI_WEB_URL", "http://127.0.0.1:8504"))
	if err != nil || (piWebURL.Scheme != "http" && piWebURL.Scheme != "https") || piWebURL.Host == "" || piWebURL.User != nil || piWebURL.RawQuery != "" || piWebURL.Fragment != "" || !isLoopbackHost(piWebURL.Hostname()) {
		return config{}, errors.New("PLIIK_PI_WEB_URL must be an HTTP(S) loopback URL")
	}
	addr := envOr("PLIIK_PORTAL_ADDR", "127.0.0.1:8080")
	host, _, err := net.SplitHostPort(addr)
	if err != nil || !isLoopbackHost(host) {
		return config{}, errors.New("PLIIK_PORTAL_ADDR must use a loopback address")
	}
	configDir, err := os.UserConfigDir()
	if err != nil {
		return config{}, err
	}
	portalDir := filepath.Join(configDir, "pliik-workstation")
	return config{
		Addr:            addr,
		PiWebURL:        piWebURL,
		ProjectsFile:    envOr("PLIIK_PROJECTS_FILE", filepath.Join(portalDir, "projects.json")),
		ProjectsDir:     envOr("PLIIK_PROJECTS_DIR", filepath.Join(os.Getenv("HOME"), "pliik-workstation", "projects")),
		CredentialsFile: envOr("PLIIK_GIT_CREDENTIALS_FILE", filepath.Join(portalDir, "git-credentials")),
	}, nil
}

func serviceAvailable(target *url.URL) bool {
	client := http.Client{Timeout: 1500 * time.Millisecond}
	response, err := client.Get(target.String())
	if err != nil {
		return false
	}
	_ = response.Body.Close()
	return response.StatusCode >= http.StatusOK && response.StatusCode < http.StatusInternalServerError
}

func newCSRFToken() (string, error) {
	var token [32]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", fmt.Errorf("generate portal CSRF token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(token[:]), nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func newApp(cfg config) (*app, error) {
	projects, err := loadProjectStore(cfg.ProjectsFile)
	if err != nil {
		return nil, err
	}
	csrfToken, err := newCSRFToken()
	if err != nil {
		return nil, err
	}
	return &app{
		cfg:         cfg,
		projects:    projects,
		validatePAT: validateGitHubPAT,
		cloneRepo:   cloneGitHubRepo,
		csrfToken:   csrfToken,
	}, nil
}

func writeJSONPrivate(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".pliik-*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0600); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempName, path)
}

func (a *app) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
		return
	}
	if r.URL.Path == "/" || r.URL.Path == "/portal" || r.URL.Path == "/login" {
		http.Redirect(w, r, "/admin", http.StatusSeeOther)
		return
	}
	if r.URL.Path == "/admin" || strings.HasPrefix(r.URL.Path, "/admin/") {
		a.handleAdmin(w, r)
		return
	}
	http.NotFound(w, r)
}

func (a *app) sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	return err == nil && u.Host != "" && strings.EqualFold(u.Host, r.Host)
}

func (a *app) validCSRFToken(token string) bool {
	return len(token) == len(a.csrfToken) && subtle.ConstantTimeCompare([]byte(token), []byte(a.csrfToken)) == 1
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("load portal configuration: %v", err)
	}
	a, err := newApp(cfg)
	if err != nil {
		log.Fatalf("initialize portal: %v", err)
	}
	server := &http.Server{Addr: cfg.Addr, Handler: a, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 2 * time.Minute}
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stopped
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()
	log.Printf("Pliik administration portal listening on %s", cfg.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("portal server: %v", err)
	}
}
