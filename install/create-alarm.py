import sys
import requests
import json
 
 def main():
     if len(sys.argv) != 6:
         print "Usage: python %s user api tenant entity checkid" % sys.argv[0]
         sys.exit(1)
          
          username = sys.argv[1]
          api_key = sys.argv[2]
          tenant = sys.argv[3]
          entity = sys.argv[4]
          check_id = sys.argv[5]
           
           url = 'https://identity.api.rackspacecloud.com/v2.0/tokens'
            
            data = {
                    "auth": {
                        "RAX-KSKEY:apiKeyCredentials": {
                            "username": username,
                            "apiKey": api_key
                            }
                        }
                    }
             
            headers = {
                    "Content-Type": "application/json",
                    "Accept": "application/json"
                    }
             
            req = requests.post(url, data=json.dumps(data), headers=headers)
            headers['X-Auth-Token'] = json.loads(req.text)['access']['token']['id']
             
             url = 'https://monitoring.api.rackspacecloud.com/v1.0/'+tenant+'/entities/'+entity+'/alarms'
              
              alarm_criteria = """if (metric['sql_ping_succeeds'] == 'false') {
              return new AlarmStatus(CRITICAL, 'holland-plugin: MySQL is not running.');
              }
              return new AlarmStatus(OK, 'holland-plugin: MySQL is running');
              """
               
               data = {"label": "test_alarm",
                       "check_id": check_id,
                       "metadata": {"template_name": "agent.holland"},
                       "notification_plan_id": "npManaged",
                       "criteria": alarm_criteria
                       }
                
                
               req = requests.post(url, data=json.dumps(data), headers=headers)
               print req.text
               print "Alarm Created"
                
                if __name__ == '__main__':
                    main()
