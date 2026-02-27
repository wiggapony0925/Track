import json
from pathlib import Path

report_path = Path('/Users/jeffreyfernandez/code/Track/TrackBackend/logs/full_nyc_network_validation_20260225.json')
report = json.loads(report_path.read_text())

bus = report['bus']['per_route']
subway = report['subway']['per_route']
lirr = report['lirr']['per_route']
mnr = report['mnr']['per_route']

no_bus_stops = [item['route_id'] for item in bus if item.get('stops_count', 0) == 0]
no_bus_schedule = [item['route_id'] for item in bus if item.get('schedule_direction_count', 0) == 0]
no_bus_live = [item['route_id'] for item in bus if item.get('vehicle_count', 0) == 0]
no_bus_shape = [item['route_id'] for item in bus if item.get('shape_stops', 0) == 0 and item.get('shape_polylines', 0) == 0]

subway_no_live = [item['route_id'] for item in subway if item.get('live_payload_size', 0) == 0]
subway_no_shape = [item['route_id'] for item in subway if item.get('shape_payload_size', 0) == 0]
lirr_no_shape = [item['route_id'] for item in lirr if item.get('shape_payload_size', 0) == 0]
mnr_no_shape = [item['route_id'] for item in mnr if item.get('shape_payload_size', 0) == 0]

print('BUS_NO_STOPS_COUNT', len(no_bus_stops))
print('BUS_NO_SCHEDULE_DIRS_COUNT', len(no_bus_schedule))
print('BUS_NO_LIVE_VEHICLES_COUNT', len(no_bus_live))
print('BUS_NO_SHAPE_COUNT', len(no_bus_shape))
print('SUBWAY_NO_LIVE_COUNT', len(subway_no_live))
print('SUBWAY_NO_SHAPE_COUNT', len(subway_no_shape))
print('LIRR_NO_SHAPE_COUNT', len(lirr_no_shape))
print('MNR_NO_SHAPE_COUNT', len(mnr_no_shape))
print('BUS_NO_STOPS_SAMPLE', no_bus_stops[:40])
print('BUS_NO_SCHEDULE_DIRS_SAMPLE', no_bus_schedule[:40])
print('BUS_NO_LIVE_VEHICLES_SAMPLE', no_bus_live[:40])
print('BUS_NO_SHAPE_SAMPLE', no_bus_shape[:40])
