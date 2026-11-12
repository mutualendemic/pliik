package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
)

func testApp(t *testing.T, piWebURL *url.URL, dir string) *app {
	t.Helper()
	app, err := newApp(config{
		PiWebURL:        piWebURL,
		ProjectsFile:    filepath.Join(dir, "projects.json"),
		ProjectsDir:     filepath.Join(dir, "projects"),
		CredentialsFile: filepath.Join(dir, "credentials"),
		AccountsFile:    filepath.Join(dir, "github-accounts.json"),
	})
	if err != nil {
		t.Fatalf("newApp() error: %v", err)
	}
	return app
}

func TestAdminRouteIsThePortalInterface(t *testing.T) {
	dir := t.TempDir()
	app := testApp(t, &url.URL{Scheme: "http", Host: "127.0.0.1:8504"}, dir)

	recorder := httptest.NewRecorder()
	app.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/admin", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("GET /admin status = %d, want %d", recorder.Code, http.StatusOK)
	}
	body := recorder.Body.String()
	if strings.Contains(body, "Code Server") || strings.Contains(body, "VS Code") || strings.Contains(body, "WORKSPACE") {
		t.Fatalf("admin page still contains workspace/Code Server UI")
	}
	if !strings.Contains(body, `name="_csrf"`) {
		t.Fatal("admin page does not include CSRF form tokens")
	}
}

func TestRemovedWorkspaceRoutesDoNotServeWorkspace(t *testing.T) {
	dir := t.TempDir()
	app := testApp(t, &url.URL{Scheme: "http", Host: "127.0.0.1:8504"}, dir)

	for _, path := range []string{"/", "/portal", "/login"} {
		t.Run(path, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			app.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
			if recorder.Code != http.StatusSeeOther || recorder.Header().Get("Location") != "/admin" {
				t.Fatalf("GET %s = status %d, Location %q; want redirect to /admin", path, recorder.Code, recorder.Header().Get("Location"))
			}
		})
	}
	for _, path := range []string{"/workspace", "/terminal", "/anything"} {
		t.Run(path, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			app.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
			if recorder.Code != http.StatusNotFound {
				t.Fatalf("GET %s status = %d, want %d", path, recorder.Code, http.StatusNotFound)
			}
		})
	}
}

func TestOpaqueOriginAdminPostRequiresCSRFToken(t *testing.T) {
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer service.Close()
	serviceURL, err := url.Parse(service.URL)
	if err != nil {
		t.Fatal(err)
	}
	app := testApp(t, serviceURL, t.TempDir())

	for _, tc := range []struct {
		name       string
		csrfToken  string
		wantStatus int
	}{
		{name: "valid token permits opaque browser origin", csrfToken: app.csrfToken, wantStatus: http.StatusBadRequest},
		{name: "missing token remains forbidden", wantStatus: http.StatusForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			form := url.Values{"name": {"missing"}}
			if tc.csrfToken != "" {
				form.Set("_csrf", tc.csrfToken)
			}
			request := httptest.NewRequest(http.MethodPost, "/admin/pi-web/register", strings.NewReader(form.Encode()))
			request.Header.Set("Origin", "null")
			request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			recorder := httptest.NewRecorder()
			app.ServeHTTP(recorder, request)
			if recorder.Code != tc.wantStatus {
				t.Fatalf("POST /admin/pi-web/register status = %d, want %d; body=%s", recorder.Code, tc.wantStatus, recorder.Body.String())
			}
		})
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
