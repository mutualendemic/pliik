package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestSelectedGitHubRepositories(t *testing.T) {
	values := url.Values{
		"repos": {"owner/repo-1,owner/repo-2", "owner/repo-1\nowner/repo-3"},
	}
	got := selectedGitHubRepositories(values)
	want := []string{"owner/repo-1", "owner/repo-2", "owner/repo-3"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("selectedGitHubRepositories() = %#v, want %#v", got, want)
	}
}

func TestRegisterPiWebProject(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/projects" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var input struct {
			Path   string `json:"path"`
			Name   string `json:"name"`
			Create bool   `json:"create"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			t.Errorf("decode request: %v", err)
		}
		if input.Path != "/tmp/projects/demo" || input.Name != "demo" || input.Create {
			t.Errorf("unexpected project input: %+v", input)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"project-id"}`))
	}))
	defer server.Close()
	base, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	id, err := registerPiWebProject(context.Background(), base, "/tmp/projects/demo", "demo")
	if err != nil {
		t.Fatalf("registerPiWebProject() error = %v", err)
	}
	if id != "project-id" {
		t.Fatalf("registerPiWebProject() id = %q, want project-id", id)
	}
}

func TestValidateGitIdentity(t *testing.T) {
	for _, tc := range []struct {
		name  string
		email string
		valid bool
	}{
		{name: "Developer", email: "dev@example.com", valid: true},
		{name: "", email: "dev@example.com"},
		{name: "Dev\nInjected", email: "dev@example.com"},
		{name: "Developer", email: "not-an-email"},
		{name: "Developer", email: "Dev <dev@example.com>"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateGitIdentity(tc.name, tc.email)
			if (err == nil) != tc.valid {
				t.Fatalf("validateGitIdentity(%q, %q) error = %v; valid = %v", tc.name, tc.email, err, tc.valid)
			}
		})
	}
}

func TestConfigureClonedRepositorySetsLocalIdentityAndCredentialHelper(t *testing.T) {
	repo := t.TempDir()
	credentialFile := filepath.Join(t.TempDir(), "credentials with 'quote")
	if output, err := exec.Command("git", "-C", repo, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, output)
	}
	if err := storeGitHubCredential(credentialFile, "test-token-value"); err != nil {
		t.Fatalf("storeGitHubCredential() error = %v", err)
	}
	if err := configureClonedRepository(repo, credentialFile, "Developer Name", "dev@example.com"); err != nil {
		t.Fatalf("configureClonedRepository() error = %v", err)
	}
	for key, want := range map[string]string{
		"user.name":         "Developer Name",
		"user.email":        "dev@example.com",
		"credential.helper": "store --file=" + shellQuote(credentialFile),
	} {
		output, err := exec.Command("git", "-C", repo, "config", "--local", "--get", key).CombinedOutput()
		if err != nil {
			t.Fatalf("read %s: %v: %s", key, err, output)
		}
		if got := strings.TrimSpace(string(output)); got != want {
			t.Errorf("local %s = %q, want %q", key, got, want)
		}
	}
	command := exec.Command("git", "-C", repo, "credential", "fill")
	command.Stdin = strings.NewReader("protocol=https\nhost=github.com\n\n")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git credential fill: %v: %s", err, output)
	}
	if !strings.Contains(string(output), "password=test-token-value") {
		t.Fatalf("credential helper did not provide the saved token: %q", output)
	}
}

func TestConfigureExistingProjectGit(t *testing.T) {
	dir := t.TempDir()
	piWeb, err := url.Parse("http://127.0.0.1:8504")
	if err != nil {
		t.Fatal(err)
	}
	app := testApp(t, piWeb, dir)
	projectPath := filepath.Join(app.cfg.ProjectsDir, "existing")
	if err := os.MkdirAll(projectPath, 0700); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("git", "-C", projectPath, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, output)
	}
	if err := storeGitHubCredential(app.cfg.CredentialsFile, "test-token-value"); err != nil {
		t.Fatalf("storeGitHubCredential() error = %v", err)
	}
	if gitAuthIsConfigured(projectPath, app.cfg.CredentialsFile) || gitIdentityIsConfigured(projectPath) {
		t.Fatal("new checkout unexpectedly reports Git setup as complete")
	}
	if err := app.projects.add(project{Name: "existing", Repository: "https://github.com/acme/existing.git"}); err != nil {
		t.Fatalf("add project: %v", err)
	}
	if err := app.configureExistingProject("existing", "Developer", "dev@example.com"); err != nil {
		t.Fatalf("configureExistingProject() error = %v", err)
	}
	if !gitAuthIsConfigured(projectPath, app.cfg.CredentialsFile) || !gitIdentityIsConfigured(projectPath) {
		t.Fatal("configured checkout should report Git authentication and identity as ready")
	}
	for key, want := range map[string]string{
		"user.name":  "Developer",
		"user.email": "dev@example.com",
	} {
		output, err := exec.Command("git", "-C", projectPath, "config", "--local", "--get", key).CombinedOutput()
		if err != nil || strings.TrimSpace(string(output)) != want {
			t.Errorf("local %s = %q, error = %v; want %q", key, strings.TrimSpace(string(output)), err, want)
		}
	}
}

func TestNormalizeGitHubRepo(t *testing.T) {
	gotURL, gotName, err := normalizeGitHubRepo("https://github.com/acme/demo.git")
	if err != nil {
		t.Fatalf("normalizeGitHubRepo() unexpected error: %v", err)
	}
	if gotURL != "https://github.com/acme/demo.git" {
		t.Fatalf("normalizeGitHubRepo() URL = %q", gotURL)
	}
	if gotName != "demo" {
		t.Fatalf("normalizeGitHubRepo() repo name = %q", gotName)
	}
}
