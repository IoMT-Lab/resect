from typing import Any
import json

class APIRequest:
    id: int = 0
    def __init__(self, action: str, payload: dict[str, Any]):
        self.action = action
        self.payload = payload
        self.version = '1.5.0'
        self.id = APIRequest.id

        APIRequest.id += 1

    def to_json(self):
        return json.dumps({
            'action': self.action, 
            'payload': self.payload, 
            'version': self.version, 
            'id': self.id
        })
    
class APIResponse:
    def __init__(self, d: dict[str, Any]):
        self.id: int = d['id']
        self.version: str = d['version']
        self.status: str = d['status']

    def get_or_throw(self) -> Any:
        raise Exception('Unknown APIResponse type')

class APISuccess(APIResponse):
    def __init__(self, d: dict[str, Any]):
        super().__init__(d)
        self.data = d['data']

    def get_or_throw(self) -> Any:
        return self.data

class APIFail(APIResponse):
    def __init__(self, d: dict[str, Any]):
        super().__init__(d)
        self.error = d['error']

    def get_or_throw(self):
        raise Exception(f'APIFail: {self.error}')

def parse_response(json_string: str | None) -> APISuccess | APIFail | None:
    if not json_string:
        return None
    
    map = json.loads(json_string)
    status = map.get('status', None)
    if status == 'success':
        return APISuccess(map)
    elif status == 'fail':
        return APIFail(map)
    else:
        return None

        
class APIEvent:
    def __init__(self):
        self.version: str = ''
        self.name: str = ''
        self.data = None

    @classmethod
    def from_json(cls, json_string) -> 'APIEvent | None':
        map = json.loads(json_string)
        if 'event' not in map:
            return None
        else:
            self = cls()
            self.version = map['version']
            self.name = map['event']
            self.data = map['data']
        return self