package main

import (
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
