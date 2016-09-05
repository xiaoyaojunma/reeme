--����ʽ�ֽ�Ϊtoken����
local _parseExpression = findmetatable('REEME_C_EXTLIB').sql_expression_parse
--date/datetime���͵�ԭ��
local datetimeMeta = getmetatable(require('reeme.orm.datetime')())
local queryMeta = require('reeme.orm.model').__index.__queryMetaTable

--����where������ֵ����field�ֶε������������ȶԣ�Ȼ������Ƿ������������������Ƿ�Ҫ����б�ܴ���
local booleanValids = { TRUE = '1', ['true'] = '1', FALSE = '0', ['false'] = '0' }
local specialExprFunctions = { distinct = 1, count = 2, as = 3 }

--�ϲ���
local builder = table.new(0, 24)

--������������Ϸ�ʽ
builder.conds = { '', 'AND ', 'OR ', 'XOR ', 'NOT ' }
--������������ʽ
builder.validJoins = { inner = 'INNER JOIN', left = 'LEFT JOIN', right = 'RIGHT JOIN', full = 'FULL JOIN' }

local processWhereValue = function(self, field, value)
	local tp = type(value)
	value = tostring(value)

	local l, quoted = #value, false
	if value:byte(1) == 39 and value:byte(l) == 39 then
		quoted = true
	end
	
	if field.type == 1 then
		--�ַ���/Binary�͵��ֶ�
		if l == 0 then
			return "''"
		end
		if not quoted then
			return ngx.quote_sql_str(value)
		end
		return value
	end
	
	if field.type == 2 then
		--�����͵��ֶ�
		if quoted then
			l = l - 2
		end
		if l <= field.maxlen then
			return quoted and value:sub(2, l + 1) or value
		end
		return nil
	end
	
	if field.type == 3 then
		--С���͵��ֶ�
		if quoted then
			l = l - 2
		end
		return quoted and value:sub(2, l + 1) or value
	end
	
	--�����͵��ֶ�
	if quoted then
		value = value:sub(2, l - 1)
	end
	return booleanValids[value]
end

--����һ��where��������������processWhere����
builder.parseWhere = function(self, condType, name, value)
	self.condString = nil	--condString��condValuesͬһʱ��ֻ�����һ����ֻ��һ���ǿ�����Ч��
	if not self.condValues then
		self.condValues = {}
	end

	name = name:trim()
	
	if value == nil then
		--name������������ʽ
		return { expr = name, c = condType }
	end
	
	puredkeyname = name:match('^[0-9A-Za-z-_]+')
	if puredkeyname and #puredkeyname == #name then
		--keyû�ж���ķ��ţ�ֻ��һ�����������
		puredkeyname = true
	else
		puredkeyname = false
	end
	
	local tv = type(value)
	if tv == 'table' then
		local mt = getmetatable(value)		
		if mt == queryMeta then
			--�Ӳ�ѯ
			return { puredkeyname = puredkeyname, n = name, sub = value, c = condType }
		end
		
		if mt == datetimeMeta then
			--��������
			value = tostring(value)
			return { expr = puredkeyname and string.format('%s=%s', name, value) or value, c = condType }
		end
		
		--{value}���ֱ���ʽ
		assert(#value > 0)
		return { expr = puredkeyname and string.format('%s=%s', name, value[1]) or value[1], c = condType }
		
	elseif value == ngx.null then
		--����Ϊnullֵ
		return { expr = puredkeyname and string.format('%s IS NULL', name) or (name .. 'NULL'), c = condType }
	end

	if type(name) == 'string' then
		--key=value
		if tv == 'string' then
			value = ngx.quote_sql_str(value)
			
		elseif puredkeyname then
			local f = self.m.__fields[name]
			if f and f.type == 1 then
				--������ֶ����ַ������ͣ����Զ�ת�ַ���
				value = ngx.quote_sql_str(tostring(value))
			end
		end
		
		return { expr = puredkeyname and string.format('%s=%s', name, value) or (name .. value), c = condType }
	end
end

--����where��������������
builder.processWhere = function(self, condType, k, v)
	local tp = type(k)
	if tp == 'table' then
		for name,val in pairs(k) do
			local where = builder.parseWhere(self, condType, name, val)
			if where then
				self.condValues[#self.condValues + 1] = where
			else
				error(string.format("process where(%s) function with illegal value(s) call", name))
			end
		end
		return self
	end
	
	if tp ~= 'string' then
		k = tostring(k)
	end

	local where = builder.parseWhere(self, condType, k, v)
	if where then
		self.condValues[#self.condValues + 1] = where
	else
		error(string.format("process where(%s) function with illegal value(s) call", name))
	end
	return self
end

--����on��������������
builder.processOn = function(self, condType, k, v)
	local tp = type(k)
	if tp == 'string' then
		local where = builder.parseWhere(self, condType, k, v)
		if where then
			if not self.onValues then
				self.onValues = { where }
			else
				self.onValues[#self.onValues + 1] = where
			end			
		else
			error(string.format("process on(%s) function call failed: illegal value or confilict with declaration of model fields", name))
		end

	elseif tp == 'table' then
		for name,val in pairs(k) do
			local where = builder.parseWhere(self, condType, name, val)
			if where then
				if not self.onValues then
					self.onValues = { where }
				else
					self.onValues[#self.onValues + 1] = where
				end
			else
				error(string.format("process on(%s) function call failed: illegal value or confilict with declaration of model fields", name))
			end
		end
	end

	return self
end

--����Where�����е���������ʽ��������ʽ���õ����ֶ����֣����ձ���alias��������������
builder.processTokenedString = function(self, alias, expr, joinFrom)
	if #alias == 0 then
		return expr
	end

	local fields = self.m.__fields
	local sql, adjust = expr, 0
	local n1, n2 = self.m.__name, joinFrom and joinFrom.m.__name or nil
	local names = self.joinNames

	local tokens, poses = _parseExpression(sql)
	if not tokens or not poses then
		return sql
	end

	local drops = 0
	for i=1, #tokens do
		local one, newone = tokens[i], nil
		if one then
			if fields[one] then
				--����һ���ֶε�����
				newone = drops > 0 and one or alias .. one
			elseif one == n1 then
				--�����Լ��ı�������ô������һ���ֶ����������ֶ����ƻᱻ�Զ��ļ���alias�����������ֻ��Ҫ�������Ƴ�����
				newone = ''
				one = one .. '.'
			elseif one == n2 then
				newone = joinFrom.alias
				drops = 2
			elseif names then
				local q = names[one]
				newone = q and self.joinNames[one].alias or nil
			end
		end
		
		if newone then
			--�滻�����յı���ʽ
			sql = sql:subreplace(newone, poses[i] + adjust, #one)
			adjust = adjust + #newone - #one
		end
		
		drops = drops - 1
	end
	
	return sql
end

--��query���õ������ϲ�ΪSQL���
builder.SELECT = function(self, model, db)
	local sqls = {}
	sqls[#sqls + 1] = 'SELECT'
	
	--main
	local alias = ''
	self.db = db
	if self.joins and #self.joins > 0 then
		self.alias = self.userAlias or '_A'
		alias = self.alias .. '.'
	end	
	
	builder.buildColumns(self, model, sqls, alias)
	
	--joins fields
	builder.buildJoinsCols(self, sqls)
	
	--from
	sqls[#sqls + 1] = 'FROM'
	sqls[#sqls + 1] = model.__name
	if #alias > 0 then
		sqls[#sqls + 1] = self.alias
	end

	--joins conditions	
	builder.buildJoinsConds(self, sqls)
	
	--where
	local haveWheres = builder.buildWheres(self, sqls, 'WHERE', alias)
	builder.buildWhereJoins(self, sqls, haveWheres)
	
	--order by
	builder.buildOrder(self, sqls, alias)
	--limit
	builder.buildLimits(self, sqls)
	
	--end
	self.db = nil
	return table.concat(sqls, ' ')
end
	
builder.UPDATE = function(self, model, db)
	local sqls = {}
	sqls[#sqls + 1] = 'UPDATE'
	sqls[#sqls + 1] = model.__name
	
	--has join(s) then alias
	local alias = ''
	self.db = db
	if self.joins and #self.joins > 0 then
		self.alias = self.userAlias or '_A'
		alias = self.alias .. '.'
		
		sqls[#sqls + 1] = self.alias
	end	

	--joins fields
	if #alias > 0 then
		builder.buildJoinsCols(self, nil)
		
		--joins conditions	
		builder.buildJoinsConds(self, sqls)
	end
	
	--all values
	if builder.buildKeyValuesSet(self, model, sqls, alias) > 0 then
		table.insert(sqls, #sqls, 'SET')
	end
	
	--where
	if not builder.buildWheres(self, sqls, 'WHERE', alias) then
		if type(self.__where) == 'string' then
			sqls[#sqls + 1] = 'WHERE'
			sqls[#sqls + 1] = builder.processTokenedString(self, alias, self.__where)
		else
			--find primary key
			local haveWheres = false
			local idx, vals = model.__fieldIndices, self.keyvals

			if vals then
				for k,v in pairs(idx) do
					if v.type == 1 then
						local v = vals[k]
						if v and v ~= ngx.null then
							builder.processWhere(self, 1, k, v)
							haveWheres = builder.buildWheres(self, sqls, 'WHERE', alias)
							break
						end
					end
				end
			end

			if not haveWheres then
				error("Cannot do model update without any conditions")
				return false
			end
		end
	end
	
	--order by
	if self.orderBy then
		sqls[#sqls + 1] = string.format('ORDER BY %s %s', self.orderBy.name, self.orderBy.order)
	end
	--limit
	builder.buildLimits(self, sqls, true)
	
	--end
	return table.concat(sqls, ' ')
end

builder.INSERT = function(self, model, db)
	local sqls = {}
	sqls[#sqls + 1] = 'INSERT INTO'
	sqls[#sqls + 1] = model.__name
	
	--all values
	if builder.buildKeyValuesSet(self, model, sqls, '') > 0 then
		table.insert(sqls, #sqls, 'SET')
	end
	
	--end
	return table.concat(sqls, ' ')
end
	
builder.DELETE = function(self, model)
	local sqls = {}
	sqls[#sqls + 1] = 'DELETE'
	sqls[#sqls + 1] = 'FROM'
	sqls[#sqls + 1] = model.__name
	
	--where
	if not builder.buildWheres(self, sqls, 'WHERE') then
		if type(self.__where) == 'string' then
			sqls[#sqls + 1] = 'WHERE'
			sqls[#sqls + 1] = builder.processTokenedString(self, '', self.__where)
		else
			--find primary or unique
			local haveWheres = false
			local idx, vals = model.__fieldIndices, self.keyvals
			if vals then
				for k,v in pairs(idx) do
					if (v.type == 1 or v.type == 2) and vals[k] then
						builder.processWhere(self, 1, k, vals[k])
						haveWheres = builder.buildWheres(self, sqls, 'WHERE', '')
						break
					end
				end
			end

			if not haveWheres then
				error("Cannot do model delete without any conditions")
				return false
			end
		end
	end
	
	--limit
	builder.buildLimits(self, sqls, true)
	
	--end
	return table.concat(sqls, ' ')
end


builder.buildColumns = function(self, model, sqls, alias, returnCols)
	--�������еı���ʽ
	local excepts, express = nil, nil
	if self.expressions then
		local fields = self.m.__fields
		local tbname = self.m.__name
		local skips = 0
		
		for i = 1, #self.expressions do
			local expr = self.expressions[i]

			if skips <= 0 and type(expr) == 'string' then
				local adjust = 0
				local tokens, poses = _parseExpression(expr)
				if tokens then
					local removeCol = false
					for k = 1, #tokens do
						local one, newone = tokens[k], nil

						if one:byte(1) == 39 then
							--����һ���ַ���
							newone = ngx.quote_sql_str(one:sub(2, -2))		
							
						elseif fields[one] then
							--����һ���ֶε�����
							if removeCol then
								if not excepts then
									excepts = {}
								end
								if self.colExcepts then
									for en,_ in pairs(self.colExcepts) do
										excepts[en] = true
									end
								end
								
								excepts[one] = true
							end
							
							newone = alias .. one

						elseif one == tbname then
							newone = alias
							one = one .. '.'

						else
							--���⴦��
							local spec = specialExprFunctions[one:lower()]
							if spec == 1 then
								--������Щ����ı���ʽ���������ʽ���������ֶξͲ��������ֶ��б��г���
								removeCol = true
							elseif spec == 2 then
								--�����excepts���ݣ�������Ϊ�գ���ΪֻҪexcepts������ڣ��ֶξͲ�����*��ʽ���֣������Ͳ�����ϳ�count(*),*�����
								if not excepts then excepts = {} end
							elseif spec == 3 then
								--AS����֮����Ҫ������һ��tokenֱ�Ӹ��Ƽ���
								skips = 2
							end

						end

						if newone then
							expr = expr:subreplace(newone, poses[k] + adjust, #one)
							adjust = adjust + #newone - #one
						end
					end

					self.expressions[i] = expr
				end

			else
				self.expressions[i] = tostring(expr)
			end

			skips = skips - 1
		end
		
		express = table.concat(self.expressions, ',')
	end
	
	if not excepts then
		excepts = self.colExcepts
	end
	
	local cols
	if self.colSelects then
		--ֻ��ȡĳ����
		local plains = {}
		if excepts then			
			for k,v in pairs(self.colSelects) do
				if not excepts[k] then
					plains[#plains + 1] = k
				end
			end
		else
			for k,v in pairs(self.colSelects) do
				plains[#plains + 1] = k
			end
		end

		cols = table.concat(plains, ',' .. alias)		
		
	elseif excepts then
		--ֻ�ų���ĳ����
		local fps = {}
		local fieldPlain = model.__fieldsPlain
		
		for i = 1, #fieldPlain do
			local n = fieldPlain[i]
			if not excepts[n] then
				fps[#fps + 1] = n
			end
		end
		
		cols = #fps > 0 and table.concat(fps, ',' .. alias) or '*'
	else
		--������
		cols = '*'
	end	

	if #alias > 0 then
		cols = #cols > 0 and (alias .. cols) or ''
	end
	if express then
		cols = #cols > 0 and string.format('%s,%s', express, cols) or express
	end

	if #cols > 0 then
		if returnCols == true then
			return cols
		end
		
		sqls[#sqls + 1] = cols
	end
end

builder.buildKeyValuesSet = function(self, model, sqls, alias)
	local fieldCfgs = model.__fields
	local vals, full = self.keyvals, self.fullop
	local isUpdate = self.op == 'UPDATE' and true or false
	local keyvals = {}

	if not vals then
		vals = self
	end

	for name,v in pairs(self.colSelects == nil and model.fields or self.colSelects) do
		local cfg = fieldCfgs[name]
		if cfg then
			local v = vals[name]
			local tp = type(v)

			if cfg.ai then
				--������ֵҪô��fullCreate/fullSaveҪô������
				if not full or not string.checkinteger(v) then
					v = nil
				end
			elseif v == nil then
				--ֵΪnil����ô�ж��Ƿ�ʹ���ֶε�Ĭ��ֵ
				if not isUpdate then
					if cfg.default then
						v = cfg.default
					elseif cfg.null then
						v = 'NULL'
					else
						v = cfg.type == 1 and "''" or '0'
					end
				end
			elseif v == ngx.null then
				--NULLֱֵ������
				v = 'NULL'
			elseif tp == 'table' then
				--table���������meta�������ж���ʲôtable
				local mt = getmetatable(v)
				
				if mt == datetimeMeta then
					--����ʱ��
					v = ngx.quote_sql_str(tostring(v))
				elseif mt == queryMeta then	
					--�Ӳ�ѯ
				else
					--�ַ���ԭֵ
					v = v[1]
				end
			elseif cfg.type == 1 then
				--�ֶ�Ҫ��Ϊ�ַ��������ת�ַ�����ת��
				v = ngx.quote_sql_str(tostring(v))
			elseif cfg.type == 4 then
				--������ʹ��1��0������
				v = toboolean(v) and '1' or '0'
			elseif cfg.type == 3 then
				--��ֵ/���������ͣ����ֵ����Ϊ������
				if not string.checknumeric(v) then
					print(string.format("model '%s': a field named '%s' its type is number but the value is not a number", model.__name, name))
					v = nil
				end
			elseif not string.checkinteger(v) then
				--����Ͷ����������ͣ����ֵ����Ϊ����
				print(string.format("model '%s': a field named '%s' its type is integer but the value is not a integer", model.__name, name))
				v = nil
			end

			if v ~= nil then
				--�����������ֵ������nil����ô�Ϳ���ʹ����
				if alias and #alias > 0 then
					keyvals[#keyvals + 1] = string.format("%s%s=%s", alias, name, v)
				else
					keyvals[#keyvals + 1] = string.format("%s=%s", name, v)
				end
			end
		end
	end

	sqls[#sqls + 1] = table.concat(keyvals, ',')
	return #keyvals
end


--���condValues��nil��˵�����ڴ����Ĳ���self������query�Լ�������
builder.buildWheres = function(self, sqls, condPre, alias, condValues)
	if not alias then alias = '' end
	
	if not condValues then
		if self.condString then
			if condPre then
				sqls[#sqls + 1] = condPre
			end
			sqls[#sqls + 1] = self.condString
			return true
		end
		
		condValues = self.condValues
	end

	if condValues and #condValues > 0 then
		local wheres, conds = {}, builder.conds
		local joinFrom = self.joinFrom
		
		for i = 1, #condValues do
			local one, rsql = condValues[i], nil
			
			if i > 1 and one.c == 1 then
				--���û��ָ���������ӷ�ʽ����ô�����ǵ�1��������ʱ�򣬾ͻ��Զ��޸�Ϊand
				one.c = 1
			end			
			
			if one.sub then
				--�Ӳ�ѯ
				local subq = one.sub
				subq.limitStart, subq.limitTotal = nil, nil
				
				local expr = builder.processTokenedString(self, alias, one.n, joinFrom)
				local subsql = builder.SELECT(subq, subq.m, self.db)
				
				if subsql then
					if one.puredkeyname then
						rsql = string.format('%s IN(%s)', expr, subsql)
					else
						rsql = string.format('%s(%s)', expr, subsql)
					end
				end
				
			else
				rsql = conds[one.c] .. builder.processTokenedString(self, alias, one.expr, joinFrom)
			end

			wheres[#wheres + 1] = rsql
		end
		
		if condPre then
			sqls[#sqls + 1] = condPre
		end
		sqls[#sqls + 1] = table.concat(wheres, ' ')
		
		return true
	end
	
	return false
end

builder.buildWhereJoins = function(self, sqls, haveWheres)
	local cc = self.joins == nil and 0 or #self.joins
	if cc < 1 then
		return
	end

	for i = 1, cc do
		local q = self.joins[i].q
		q.joinFrom = self
		builder.buildWheres(q, sqls, haveWheres and 'AND' or 'WHERE', q.alias .. '.')
		q.joinFrom = nil
	end
end

builder.buildJoinsCols = function(self, sqls, indient)
	local cc = self.joins == nil and 0 or #self.joins
	if cc < 1 then
		return
	end
	if indient == nil then
		indient = 1
	end	

	for i = 1, cc do
		local q = self.joins[i].q
		q.alias = q.userAlias or ('_' .. string.char(65 + indient))

		if sqls then
			local cols = builder.buildColumns(q, q.m, sqls, q.alias .. '.', true)
			if cols then
				sqls[#sqls + 1] = ','
				sqls[#sqls + 1] = cols
			end
		end
		
		local newIndient = builder.buildJoinsCols(q, sqls, indient + 1)
		indient = newIndient or (indient + 1)
	end
	
	return indient
end

builder.buildJoinsConds = function(self, sqls, haveOns)
	local cc = self.joins == nil and 0 or #self.joins
	if cc < 1 then
		return
	end
	
	local validJoins = builder.validJoins
	
	for i = 1, cc do
		local join = self.joins[i]
		local q = join.q
		
		q.joinFrom = self

		sqls[#sqls + 1] = validJoins[join.type]
		sqls[#sqls + 1] = q.m.__name
		sqls[#sqls + 1] = q.alias
		sqls[#sqls + 1] = 'ON('
		if not builder.buildWheres(q, sqls, nil, q.alias .. '.', q.onValues) then		
			sqls[#sqls + 1] = '1'
		end
		sqls[#sqls + 1] = ')'
		
		q.joinFrom = nil
		
		builder.buildJoinsConds(q, sqls, haveOns)
	end
end

builder.buildOrder = function(self, sqls, alias)
	if self.orderBy then
		if type(self.orderBy) == 'string' then
			sqls[#sqls + 1] = 'ORDER BY'
			sqls[#sqls + 1] = self.orderBy
		else
			sqls[#sqls + 1] = string.format('ORDER BY %s%s %s', alias, 		self.orderBy.name, self.orderBy.order)
		end
	end
end

builder.buildLimits = function(self, sqls, ignoreStart)
	if self.limitTotal and self.limitTotal > 0 then
		if ignoreStart then
			sqls[#sqls + 1] = string.format('LIMIT %u', self.limitTotal)
		else
			sqls[#sqls + 1] = string.format('LIMIT %u,%u', self.limitStart, self.limitTotal)
		end
	end
end

return builder