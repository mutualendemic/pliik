package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPortalAndAdminRoutesDoNotRequireAuthentication(t *testing.T) {
	dir := t.TempDir()
	app, err := newApp(config{
		PiWebURL:        &url.URL{Scheme: "http", Host: "127.0.0.1:8504"},
		CodeServerURL:   &url.URL{Scheme: "http", Host: "127.0.0.1:18080"},
		UsersFile:       filepath.Join(dir, "users.json"),
		ProjectsFile:    filepath.Join(dir, "projects.json"),
		ProjectsDir:     filepath.Join(dir, "projects"),
		CredentialsFile: filepath.Join(dir, "credentials"),
	})
	if err != nil {
		t.Fatalf("newApp() error: %v", err)
	}

	for _, path := range []string{"/portal", "/admin"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			recorder := httptest.NewRecorder()
			app.ServeHTTP(recorder, request)

			if recorder.Code != http.StatusOK {
				t.Fatalf("GET %s status = %d, want %d", path, recorder.Code, http.StatusOK)
			}
			if strings.Contains(recorder.Body.String(), "Entrar na workstation") {
				t.Fatalf("GET %s unexpectedly rendered a login page", path)
			}
		})
	}
}

func TestDefaultProjectOpensItsActualProjectsDirectory(t *testing.T) {
	var gotFolder string
	codeServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotFolder = r.URL.Query().Get("folder")
		w.WriteHeader(http.StatusOK)
	}))
	defer codeServer.Close()
	codeServerURL, err := url.Parse(codeServer.URL)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	projectsDir := filepath.Join(dir, "projects")
	projectDir := filepath.Join(projectsDir, "demo")
	if err := os.MkdirAll(projectDir, 0700); err != nil {
		t.Fatal(err)
	}
	app, err := newApp(config{
		PiWebURL:        &url.URL{Scheme: "http", Host: "127.0.0.1:8504"},
		CodeServerURL:   codeServerURL,
		UsersFile:       filepath.Join(dir, "users.json"),
		ProjectsFile:    filepath.Join(dir, "projects.json"),
		ProjectsDir:     projectsDir,
		CredentialsFile: filepath.Join(dir, "credentials"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := app.projects.add(project{Name: "demo"}, true); err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	app.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("GET / status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if gotFolder != projectDir {
		t.Fatalf("default folder = %q, want %q", gotFolder, projectDir)
	}
}

func TestPortalListenerAddressMustBeLoopback(t *testing.T) {
	for _, host := range []string{"127.0.0.1", "::1", "localhost"} {
		if !isLoopbackHost(host) {
			t.Errorf("isLoopbackHost(%q) = false, want true", host)
		}
	}
	for _, host := range []string{"0.0.0.0", "192.0.2.1", "example.com"} {
		if isLoopbackHost(host) {
			t.Errorf("isLoopbackHost(%q) = true, want false", host)
		}
	}
}
