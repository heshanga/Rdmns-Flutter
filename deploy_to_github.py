import os
import sys
import base64
import requests

# Never hard-code the token: set it in the environment before running.
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
if not GITHUB_TOKEN:
    sys.exit("Set the GITHUB_TOKEN environment variable first.")
REPO_NAME = "Rdmns-Flutter"
SOURCE_DIR = os.environ.get("RDMNS_SOURCE_DIR", r"c:\Users\hesha\Documents\Rdmns Flutter")

headers = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github.v3+json"
}

def get_username():
    r = requests.get("https://api.github.com/user", headers=headers)
    if r.status_code == 200:
        return r.json()["login"]
    else:
        print(f"Error fetching user info: {r.status_code} - {r.text}")
        sys.exit(1)

def ensure_repo(owner):
    r = requests.get(f"https://api.github.com/repos/{owner}/{REPO_NAME}", headers=headers)
    if r.status_code == 404:
        print(f"Creating repository '{REPO_NAME}' on GitHub...")
        payload = {"name": REPO_NAME, "private": False, "auto_init": False}
        cr = requests.post("https://api.github.com/user/repos", headers=headers, json=payload)
        if cr.status_code in [200, 201]:
            print(f"Repository '{REPO_NAME}' created successfully!")
        else:
            print(f"Failed to create repo: {cr.status_code} - {cr.text}")
            sys.exit(1)
    else:
        print(f"Repository '{REPO_NAME}' already exists on GitHub.")

def upload_file(owner, file_path, rel_path):
    url = f"https://api.github.com/repos/{owner}/{REPO_NAME}/contents/{rel_path}"
    
    with open(file_path, "rb") as f:
        content_b64 = base64.b64encode(f.read()).decode("utf-8")
        
    for attempt in range(1, 4):
        try:
            get_r = requests.get(url, headers=headers, timeout=15)
            sha = None
            if get_r.status_code == 200:
                sha = get_r.json().get("sha")
                
            payload = {
                "message": f"Upload {rel_path}",
                "content": content_b64
            }
            if sha:
                payload["sha"] = sha
                
            put_r = requests.put(url, headers=headers, json=payload, timeout=30)
            if put_r.status_code in [200, 201]:
                print(f"Uploaded: {rel_path}")
                return
            else:
                print(f"Failed uploading {rel_path}: {put_r.status_code} - {put_r.text}")
                return
        except Exception as e:
            print(f"Attempt {attempt} failed for {rel_path}: {e}")
            import time
            time.sleep(2)

def main():
    username = get_username()
    print(f"Authenticated GitHub User: {username}")
    
    ensure_repo(username)
    
    for root, dirs, files in os.walk(SOURCE_DIR):
        for file in files:
            if file.endswith(".zip") or file == "deploy_to_github.py":
                continue
                
            abs_path = os.path.join(root, file)
            rel_path = os.path.relpath(abs_path, SOURCE_DIR).replace("\\", "/")
            
            upload_file(owner=username, file_path=abs_path, rel_path=rel_path)
            
    print(f"\nAll Flutter project files uploaded successfully to https://github.com/{username}/{REPO_NAME}")
    print("GitHub Actions Cloud Build (Android APK & iOS IPA) triggered automatically!")

if __name__ == "__main__":
    main()
