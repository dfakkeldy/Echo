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
    url = f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appCustomProductPages"
    headers = {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json'
    }
    
    response = requests.get(url, headers=headers)
    if response.status_code != 200:
        print(f"Error fetching existing custom product pages: {response.status_code} - {response.text}")
        sys.exit(1)
        
    return response.json().get('data', [])

def create_custom_product_page(app_id, name, promo_text, token):
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
        print(f"✅ Successfully created Custom Product Page: '{name}'")
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
    existing_pages = get_existing_pages(app_id, token)
    existing_names = {page['attributes']['name'] for page in existing_pages}
    
    print(f"Found {len(existing_pages)} existing page(s): {', '.join(existing_names) if existing_names else 'None'}")
    
    pages_to_create = [
        {
            "name": "ADHD & Focus",
            "promo": "Built neurodivergent-first. Smart Rewind handles attention drift, and hands-free bookmarking lets you save thoughts without breaking focus. 100% private."
        },
        {
            "name": "Dyslexia & Read-Along",
            "promo": "Boost comprehension. Visual word-sync highlights every spoken sentence in real time. Works offline with on-device CoreML. No data leaves your device."
        },
        {
            "name": "Audiobook Study & Spaced Repetition",
            "promo": "Turn listening into keeping. Capture audio bookmarks, write notes, and review study cards daily. Built-in spaced repetition & Anki integration."
        }
    ]
    
    for page in pages_to_create:
        name = page["name"]
        promo = page["promo"]
        if name in existing_names:
            print(f"Skipping '{name}' - already exists.")
        else:
            create_custom_product_page(app_id, name, promo, token)

if __name__ == '__main__':
    main()
