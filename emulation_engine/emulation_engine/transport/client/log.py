import socketio

class LogNamespace(socketio.AsyncClientNamespace):
    def __init__(self, namespace='/log'):
        super().__init__(namespace)

    def on_connect(self):
        pass
    
    def on_disconnect(self, reason):
        pass

    async def call_log_level(self, level : str):
        return await self.call('log_level', level)