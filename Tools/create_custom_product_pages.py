# SPDX-License-Identifier: GPL-3.0-or-later
import os
import sys
import json
import time
import jwt
import requests

def load_credentials(filepath):
    with open(filepath, 'r') as f:
        return json.load(f)

def generate_jwt(key_id, issuer_id, private_key_content):
    headers = {
        'alg': 'ES256',
        'kid': key_id,
        'typ': 'JWT'
    }
    
    payload = {
        'iss': issuer_id,
        'iat': int(time.time()),
        'exp': int(time.time()) + 1200,  # 20 minutes
        'aud': 'appstoreconnect-v1'
    }
    
    return jwt.encode(payload, private_key_content, algorithm='ES256', headers=headers)

def get_existing_pages(app_id, token):
    # Request custom product pages and include their versions
    url = f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appCustomProductPages?include=appCustomProductPageVersions"
    headers = {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json'
    }
    
    response = requests.get(url, headers=headers)
    if response.status_code != 200:
        print(f"Error fetching existing custom product pages: {response.status_code} - {response.text}")
        sys.exit(1)
        
    res_json = response.json()
    pages = res_json.get('data', [])
    included = res_json.get('included', [])
    
    # Map version ID to its attributes (including deepLink)
    versions_map = {}
    for item in included:
        if item['type'] == 'appCustomProductPageVersions':
            versions_map[item['id']] = item.get('attributes', {})
            
    return pages, versions_map

def patch_version_deep_link(version_id, deep_link, token):
    url = f"https://api.appstoreconnect.apple.com/v1/appCustomProductPageVersions/{version_id}"
    headers = {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json'
    }
    
    payload = {
        "data": {
            "type": "appCustomProductPageVersions",
            "id": version_id,
            "attributes": {
                "deepLink": deep_link
            }
        }
    }
    
    response = requests.patch(url, headers=headers, json=payload)
    if response.status_code == 200:
        print(f"✅ Successfully patched deep link '{deep_link}' for version {version_id}")
        return True
    else:
        print(f"❌ Failed to patch deep link for version {version_id}: {response.status_code} - {response.text}")
        return False

def create_custom_product_page(app_id, name, promo_text, deep_link, token):
    url = "https://api.appstoreconnect.apple.com/v1/appCustomProductPages"
    headers = {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json'
    }
    
    version_id = "${version_1}"
    locale_id = "${locale_1}"
    
    payload = {
        "data": {
            "type": "appCustomProductPages",
            "attributes": {
                "name": name
            },
            "relationships": {
                "app": {
                    "data": {
                        "type": "apps",
                        "id": app_id
                    }
                },
                "appCustomProductPageVersions": {
                    "data": [
                        { "type": "appCustomProductPageVersions", "id": version_id }
                    ]
                }
            }
        },
        "included": [
            {
                "type": "appCustomProductPageVersions",
                "id": version_id,
                "attributes": {
                    "deepLink": deep_link
                },
                "relationships": {
                    "appCustomProductPageLocalizations": {
                        "data": [
                            { "type": "appCustomProductPageLocalizations", "id": locale_id }
                        ]
                    }
                }
            },
            {
                "type": "appCustomProductPageLocalizations",
                "id": locale_id,
                "attributes": {
                    "locale": "en-US",
                    "promotionalText": promo_text
                }
            }
        ]
    }
    
    response = requests.post(url, headers=headers, json=payload)
    if response.status_code == 201:
        print(f"✅ Successfully created Custom Product Page: '{name}' with deep link '{deep_link}'")
        return response.json().get('data', {})
    else:
        print(f"❌ Failed to create Custom Product Page '{name}': {response.status_code} - {response.text}")
        return None

def main():
    api_key_path = "fastlane/api_key.json"
    app_id = "6779836394"
    
    if not os.path.exists(api_key_path):
        print(f"Error: API key file not found at {api_key_path}")
        sys.exit(1)
        
    credentials = load_credentials(api_key_path)
    key_id = credentials['key_id']
    issuer_id = credentials['issuer_id']
    private_key = credentials['key']
    
    print("Generating App Store Connect JWT token...")
    token = generate_jwt(key_id, issuer_id, private_key)
    
    print("Fetching existing custom product pages...")
    existing_pages, versions_map = get_existing_pages(app_id, token)
    
    pages_to_create = [
        {
            "name": "ADHD & Focus",
            "promo": "Built neurodivergent-first. Smart Rewind handles attention drift, and hands-free bookmarking lets you save thoughts without breaking focus. 100% private.",
            "deep_link": "echoaudio://focus"
        },
        {
            "name": "Dyslexia & Read-Along",
            "promo": "Boost comprehension. Visual word-sync highlights every spoken sentence in real time. Works offline with on-device CoreML. No data leaves your device.",
            "deep_link": "echoaudio://read"
        },
        {
            "name": "Audiobook Study & Spaced Repetition",
            "promo": "Turn listening into keeping. Capture audio bookmarks, write notes, and review study cards daily. Built-in spaced repetition & Anki integration.",
            "deep_link": "echoaudio://study"
        }
    ]
    
    # Map page name to page resource
    pages_by_name = {page['attributes']['name']: page for page in existing_pages}
    
    for page in pages_to_create:
        name = page["name"]
        promo = page["promo"]
        deep_link = page["deep_link"]
        
        if name in pages_by_name:
            # Page exists, check if we need to patch the deep link of its version
            page_data = pages_by_name[name]
            versions_data = page_data.get('relationships', {}).get('appCustomProductPageVersions', {}).get('data', [])
            
            if versions_data:
                # Get the first/latest version
                version_id = versions_data[0]['id']
                version_attributes = versions_map.get(version_id, {})
                current_deep_link = version_attributes.get('deepLink')
                
                if current_deep_link == deep_link:
                    print(f"ℹ️ Page '{name}' already has deep link '{deep_link}'. No update needed.")
                else:
                    print(f"🔄 Page '{name}' has deep link '{current_deep_link}'. Patching to '{deep_link}'...")
                    patch_version_deep_link(version_id, deep_link, token)
            else:
                print(f"⚠️ Page '{name}' exists but has no versions relationship. This is unexpected.")
        else:
            # Create page with deep link
            create_custom_product_page(app_id, name, promo, deep_link, token)

if __name__ == '__main__':
    main()
