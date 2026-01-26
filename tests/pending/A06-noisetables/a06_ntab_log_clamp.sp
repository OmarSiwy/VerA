* LRM 4.6.4.4 noise_table_log: no extrapolation below or above the table
* Expected results: a06_ntab_log_clamp.expected.json
.hdl "a06_ntab.assets/a06_noiseless_res.va"
.hdl "a06_ntab.assets/a06_ntab_log.va"
Vin in 0 DC 0 AC 1
Ns in out a06_noiseless_res
Nt out 0 a06_ntab_log
.noise v(out) Vin lin 2 500 2000000
.end
