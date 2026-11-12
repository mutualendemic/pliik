package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
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
