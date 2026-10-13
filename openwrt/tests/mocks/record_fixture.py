#!/usr/bin/env python3
"""Synthetic jfself pages: 120 rows per disjoint date window, newest first."""
import json
import os
import sys
from urllib.parse import urlparse, parse_qs

query = parse_qs(urlparse(sys.argv[1]).query)
page = int(query.get('pageNumber', ['1'])[0])
end = query.get('endTime', ['2026-10-13'])[0]
total=120 if end=='2026-06-30' else 1
rows = [dict(loginTime=f'{end} #{i}', logoutTime='end', flow=str(i),
             userIp='192.0.2.2', userPassword='private-field', sessionId='private-session')
        for i in range((page-1)*100, min(page*100, total))]
if os.environ.get('MOCK_NUMERIC_RECORD_DATES') == '1':
    for row in rows:
        row.update(loginTime=1791820800000, logoutTime='1791820860000', flow='1791820800000')
print(json.dumps(dict(total=total, rows=rows)))
