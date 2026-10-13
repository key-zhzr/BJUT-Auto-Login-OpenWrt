#!/usr/bin/env python3
"""Synthetic jfself pages: 120 rows per disjoint date window, newest first."""
import json
import sys
from urllib.parse import urlparse, parse_qs

query = parse_qs(urlparse(sys.argv[1]).query)
page = int(query.get('pageNumber', ['1'])[0])
end = query.get('endTime', ['2026-10-13'])[0]
total=120 if end=='2026-06-30' else 1
rows = [dict(loginTime=f'{end} #{i}', logoutTime='end', flow=str(i),
             userIp='192.0.2.2', userPassword='private-field', sessionId='private-session')
        for i in range((page-1)*100, min(page*100, total))]
print(json.dumps(dict(total=total, rows=rows)))
