"""Debug script: check which Entra identity is being used for Redis auth."""
import json
import base64
from azure.identity import DefaultAzureCredential

c = DefaultAzureCredential()
t = c.get_token("https://redis.azure.com/.default")

p = t.token.split(".")[1]
p += "=" * (-len(p) % 4)
claims = json.loads(base64.b64decode(p))

print("OID:", claims.get("oid"))
print("UPN:", claims.get("upn"))
print("Name:", claims.get("name"))
print("AppID:", claims.get("appid"))
