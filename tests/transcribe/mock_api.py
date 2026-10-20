import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        data = json.loads(req['messages'][1]['content'])
        schema = req.get('response_format', {}).get('json_schema', {}).get('name')
        if self.path == '/fail-glossary' and schema == 'course_glossary':
            self.send_error(400, 'Intentional test failure')
            return
        finish = 'stop'
        if schema == 'transcript_items':
            time.sleep(0.03 if data['items'][0]['source_id'] % 2 else 0.12)
            if self.path == '/truncate':
                finish = 'length'
            result = {'items': [{**x, 'sentence_end': True} for x in data['items']]}
        elif schema == 'transcript_structure':
            result = {'outline': 'A test lecture about recurrent networks.',
                      'paragraph_end_ids': [x['sentence_id'] for x in data]}
        elif schema == 'semantic_splits':
            result = {'split_end_ids': [x['candidate_sentence_ids'][0] for x in data['split_targets']]}
        elif schema == 'lecture_notes':
            result = {'items': [{'source_id': x['source_id'], 'include': True,
                                 'heading': '', 'markdown': x['text'],
                                 'review_note': 'Test uncertainty.' if self.path == '/review' else ''}
                                for x in data['items']]}
        elif schema == 'course_glossary':
            result = {'topic': 'Test neural networks', 'terms': [
                {'term': term, 'observed_form': '', 'canonical_confidence': 4,
                 'evidence': 4, 'relevance': 4, 'asr_risk': 3, 'importance': 4}
                for term in ['recurrent network', 'fixed point', 'eigenvalue']]}
        else:
            result = 'A test outline.'
        content = result if isinstance(result, str) else json.dumps(result)
        body = json.dumps({'choices': [{'finish_reason': finish, 'message': {'content': content}}],
                           'usage': {'completion_tokens': 8192 if finish == 'length' else 100}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
